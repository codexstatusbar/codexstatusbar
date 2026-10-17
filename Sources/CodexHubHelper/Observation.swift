import Foundation
import CoreFoundation
import Darwin
import CodexHubCore

// Only this serial queue owns framing and metadata. Forwarders never wait for it.
final class Observation: @unchecked Sendable {
    private let queue = DispatchQueue(label: "codex-hub.observation", qos: .utility)
    private let slots = DispatchSemaphore(value: 32)
    private let lock = NSLock()
    private var accepting = true
    private var disabled = false
    private let serverFrames = ObservationFrames(client: false)
    private let clientFrames = ObservationFrames(client: true)
    private var timer: DispatchSourceTimer?
    private lazy var live = VisibleEstimator { [weak self] thread, payload, time in
        self?.emit(thread: thread, payload: payload, received: time)
    }
    private var files: [String: Int32] = [:]
    private var emittedBytes = 0
    private var timingBuffer = Data()
    private var droppingTimingLine = false
    private let directory: Int32
    private let run: String
    private let home: String
    private let status: Int32
    private let processes: [String: Any]

    init(directory: Int32, run: String, home: String, processes: [String: Any]) throws {
        self.processes = processes
        self.directory = directory; self.run = run; self.home = home
        status = try privateFile(in: directory, name: "run-events.jsonl")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, !self.disabled else { return }
            self.live.tick(DispatchTime.now().uptimeNanoseconds)
        }
        self.timer = timer
        timer.resume()
    }

    deinit {
        timer?.cancel()
        files.values.forEach { close($0) }
        close(status); close(directory)
    }

    func submit(_ bytes: Data) { submit(bytes, client: false) }
    func submitClient(_ bytes: Data) { submit(bytes, client: true) }

    func submitTiming(_ bytes: Data) {
        guard slots.wait(timeout: .now()) == .success else { return }
        queue.async {
            defer { self.slots.signal() }
            guard !self.disabled else { return }
            for byte in bytes {
                if byte == 10 {
                    if !self.droppingTimingLine,
                       let line = String(data: self.timingBuffer, encoding: .utf8),
                       let timing = ServerTiming.parse(logLine: line),
                       let data = try? JSONEncoder().encode(timing),
                       let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.emit(thread: timing.threadID, payload: ["type": "hub_server_timing", "turn_id": timing.turnID, "timing": fields], received: DispatchTime.now().uptimeNanoseconds)
                    }
                    self.timingBuffer.removeAll(keepingCapacity: true)
                    self.droppingTimingLine = false
                } else if !self.droppingTimingLine {
                    if self.timingBuffer.count < 65_536 { self.timingBuffer.append(byte) }
                    else { self.timingBuffer.removeAll(keepingCapacity: true); self.droppingTimingLine = true }
                }
            }
        }
    }

    private func submit(_ bytes: Data, client: Bool) {
        let received = DispatchTime.now().uptimeNanoseconds
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        guard slots.wait(timeout: .now()) == .success else {
            accepting = false
            queue.async { self.stop("observer_queue_overflow") }
            return
        }
        queue.async {
            defer { self.slots.signal() }
            guard !self.disabled else { return }
            do {
                try (client ? self.clientFrames : self.serverFrames).consume(bytes) { data in
                    guard !self.disabled else { return }
                    self.observe(data, client: client, received: received)
                }
            } catch {
                self.stop((error as? ObservationFrameError)?.reason ?? "unsupported_frame")
            }
        }
    }

    func finish() {
        let done = DispatchSemaphore(value: 0)
        queue.async {
            self.stop("connection_closed")
            let payload: [String: Any] = ["type": "hub_connection", "state": "disconnected"]
            self.record("event_msg", thread: nil, payload: payload, fd: self.status)
            for (thread, fd) in self.files { self.record("event_msg", thread: thread, payload: payload, fd: fd) }
            done.signal()
        }
        // A stalled metadata filesystem must not hold the helper/server lifecycle open.
        _ = done.wait(timeout: .now() + 1)
    }

    private func record(_ type: String, thread: String?, payload: [String: Any], fd: Int32, received: UInt64? = nil) {
        var row: [String: Any] = ["hub_schema_version": 1, "hub_source": "direct-relay",
            "run_id": run, "codex_home_id": home, "timestamp": ISO8601DateFormatter().string(from: Date()),
            "received_monotonic_ns": String(received ?? DispatchTime.now().uptimeNanoseconds), "type": type, "payload": payload]
        if let thread { row["thread_id"] = thread }
        guard var bytes = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        bytes.append(10)
        if !writeAll(fd, bytes) { disabled = true; live.clear(); serverFrames.clear(); clientFrames.clear(); timer?.cancel() }
        emittedBytes += bytes.count
    }

    private func stop(_ reason: String) {
        guard !disabled else { return }
        disabled = true
        serverFrames.clear(); clientFrames.clear(); live.clear(); timer?.cancel()
        let payload: [String: Any] = ["type": "measurement_gap", "reason": reason]
        record("event_msg", thread: nil, payload: payload, fd: status)
        for (thread, fd) in files { record("event_msg", thread: thread, payload: payload, fd: fd) }
    }

    private func requestID(_ value: Any?) -> Any? {
        if let string = observedIdentifier(value) { return string }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           let integer = Int64(number.stringValue) { return integer }
        return nil
    }

    private func observe(_ data: Data, client: Bool, received: UInt64) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            stop("invalid_json"); return
        }
        live.observe(json, client: client, time: received)
        if live.exhausted { stop("metadata_bound"); return }
        guard !client, !disabled else { return }
        guard let method = json["method"] as? String,
              let params = json["params"] as? [String: Any] else { return }
        let supported = ["turn/started", "turn/completed", "thread/tokenUsage/updated", "item/started", "item/completed", "serverRequest/resolved",
                         "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval"]
        guard supported.contains(method) else { return }
        guard let thread = observedIdentifier(params["threadId"]) else { stop("invalid_identifier"); return }
        var payload: [String: Any]
        switch method {
        case "turn/started", "turn/completed":
            guard let turn = params["turn"] as? [String: Any], let id = observedIdentifier(turn["id"]) else { stop("invalid_identifier"); return }
            payload = ["type": method == "turn/started" ? "task_started" : "task_complete", "turn_id": id]
            if let state = turn["status"] as? String, ["inProgress", "completed", "interrupted", "failed"].contains(state) { payload["status"] = state }
        case "thread/tokenUsage/updated":
            guard let turn = observedIdentifier(params["turnId"]), let usage = params["tokenUsage"] as? [String: Any],
                  let total = usage["total"] as? [String: Any] else { stop("invalid_usage"); return }
            let fields = [("inputTokens", "input_tokens"), ("cachedInputTokens", "cached_input_tokens"),
                          ("outputTokens", "output_tokens"), ("reasoningOutputTokens", "reasoning_output_tokens"),
                          ("totalTokens", "total_tokens"), ("cacheWriteInputTokens", "cache_write_input_tokens")]
            var counts: [String: Int64] = [:]
            for (source, target) in fields {
                if source == "cacheWriteInputTokens", total[source] == nil { continue }
                guard let number = total[source] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let integer = Int64(number.stringValue), integer >= 0 else { stop("invalid_usage"); return }
                counts[target] = integer
            }
            payload = ["type": "token_count", "turn_id": turn, "info": ["total_token_usage": counts]]
        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any], let kind = item["type"] as? String,
                  ["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "collabAgentToolCall", "webSearch", "imageGeneration"].contains(kind) else { return }
            guard let turn = observedIdentifier(params["turnId"]), let itemID = observedIdentifier(item["id"]) else { stop("invalid_identifier"); return }
            payload = ["type": method == "item/started" ? "hub_tool_started" : "hub_tool_completed", "turn_id": turn, "item_id": itemID, "tool_kind": kind]
        case "serverRequest/resolved":
            guard let id = requestID(params["requestId"]) else { stop("invalid_identifier"); return }
            payload = ["type": "hub_approval_resolved", "request_id": id]
        default:
            guard let id = requestID(json["id"]), let turn = observedIdentifier(params["turnId"]) else { stop("invalid_identifier"); return }
            payload = ["type": "hub_approval_requested", "request_id": id, "turn_id": turn]
        }
        emit(thread: thread, payload: payload, received: received)
    }

    private func emit(thread: String, payload: [String: Any], received: UInt64) {
        guard !disabled else { return }
        if emittedBytes >= 16 * 1_048_576 { stop("metadata_bound"); return }
        if files[thread] == nil {
            guard files.count < 256 else { stop("thread_bound"); return }
            do {
                let fd = try privateFile(in: directory, name: UUID().uuidString.lowercased() + ".jsonl")
                files[thread] = fd
                record("session_meta", thread: thread, payload: ["id": thread, "processes": processes], fd: fd)
            } catch { stop("metadata_unavailable"); return }
        }
        if !disabled, let fd = files[thread] { record("event_msg", thread: thread, payload: payload, fd: fd, received: received) }
    }
}

private struct ObservationFrameError: Error { let reason: String }

private final class ObservationFrames {
    private let client: Bool
    private var buffer = Data()
    private var message = Data()
    private var fragmented = false
    private var upgraded = false
    private let limit = 1_048_576
    init(client: Bool) { self.client = client }
    func clear() { buffer.removeAll(); message.removeAll() }
    func consume(_ bytes: Data, emit: (Data) -> Void) throws {
        guard buffer.count + bytes.count <= limit + 65_536 else { throw ObservationFrameError(reason: "frame_bound") }
        buffer.append(bytes)
        if !upgraded {
            guard let end = buffer.range(of: Data([13, 10, 13, 10])) else {
                if buffer.count > 16_384 { throw ObservationFrameError(reason: "upgrade_bound") }
                return
            }
            guard end.upperBound <= 16_384,
                  let header = String(data: buffer[..<end.upperBound], encoding: .utf8),
                  (client ? header.hasPrefix("GET ") : header.hasPrefix("HTTP/1.1 101 ")),
                  (client || !header.lowercased().contains("sec-websocket-extensions:")) else {
                throw ObservationFrameError(reason: "unsupported_upgrade")
            }
            buffer = Data(buffer[end.upperBound...]); upgraded = true
        }
        while buffer.count >= 2 {
            let first = buffer[0], second = buffer[1]
            let final = first & 0x80 != 0, opcode = first & 0x0f
            guard first & 0x70 == 0, (second & 0x80 != 0) == client else { throw ObservationFrameError(reason: "unsupported_frame") }
            var length = UInt64(second & 0x7f)
            var header = 2
            if length == 126 { header = 4 }
            if length == 127 { header = 10 }
            guard buffer.count >= header else { return }
            if header > 2 {
                length = 0
                for byte in buffer[2..<header] { length = (length << 8) | UInt64(byte) }
            }
            guard length <= UInt64(limit) else { throw ObservationFrameError(reason: "frame_bound") }
            let maskOffset = header
            if client { header += 4 }
            let end = header + Int(length)
            guard buffer.count >= end else { return }
            var payload = Data(buffer[header..<end])
            if client {
                for index in payload.indices { payload[index] ^= buffer[maskOffset + index % 4] }
            }
            buffer = Data(buffer[end...])
            if opcode >= 8 {
                guard final, length <= 125, [8, 9, 10].contains(opcode) else { throw ObservationFrameError(reason: "unsupported_frame") }
                continue
            }
            guard (opcode == 1 && !fragmented) || (opcode == 0 && fragmented),
                  message.count + payload.count <= limit else { throw ObservationFrameError(reason: "unsupported_message") }
            message.append(payload)
            fragmented = !final
            if final {
                emit(message)
                message.removeAll(keepingCapacity: false)
            }
        }
    }

}
