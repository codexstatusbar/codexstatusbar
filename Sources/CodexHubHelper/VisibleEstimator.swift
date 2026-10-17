import Foundation
import CryptoKit
import CoreFoundation
import Darwin

// Ordinary-text BPE only: never interpret special-token-looking user text as control tokens.
private struct OrdinaryBPE {
    private let ranks: [Data: Int]
    private let regex: NSRegularExpression
    static let models: Set<String> = ["o1", "o3", "o4-mini", "gpt-5", "gpt-4.1", "gpt-4o"]

    init() throws {
        #if SWIFT_PACKAGE
        // Bundle.module traps if packaging omitted the bundle; observation must fail closed instead.
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0, size <= 16_384 else { throw LiveFailure.resource }
        var path = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&path, &size) == 0 else { throw LiveFailure.resource }
        let executableDirectory = URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).resolvingSymlinksInPath().deletingLastPathComponent()
        let bundle = [executableDirectory, Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
            .compactMap { Bundle(url: $0.appendingPathComponent("CodexHub_CodexHubHelper.bundle")) }.first
        guard let resources = bundle?.resourceURL else { throw LiveFailure.resource }
        let root = resources.appendingPathComponent("Resources")
        #else
        guard let resources = Bundle.main.resourceURL else { throw LiveFailure.resource }
        let root = resources.appendingPathComponent("Resources")
        #endif
        func asset(_ name: String, hash: String) throws -> Data {
            let url = root.appendingPathComponent(name)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 4_000_000 else { throw LiveFailure.resource }
            let data = try Data(contentsOf: url)
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash else { throw LiveFailure.resource }
            return data
        }
        let data = try asset("o200k_base.tiktoken", hash: "446a9538cb6c348e3516120d7c08b09f57c36495e2acfffe59a5bf8b0cfb1a2d")
        let pattern = try asset("o200k_base.pattern", hash: "2d1b8dc11e89af71459b36004f698ab3693f59fd84f63e8ec2b49564ab857420")
        guard let text = String(data: data, encoding: .utf8), let expression = String(data: pattern, encoding: .utf8) else { throw LiveFailure.resource }
        var decoded: [Data: Int] = [:]
        for (rank, line) in text.split(separator: "\n").enumerated() {
            let fields = line.split(separator: " ")
            guard fields.count == 2, Int(fields[1]) == rank,
                  let bytes = Data(base64Encoded: String(fields[0])), !bytes.isEmpty,
                  decoded.updateValue(rank, forKey: bytes) == nil else { throw LiveFailure.resource }
        }
        guard decoded.count == 199_998, (0...255).allSatisfy({ decoded[Data([UInt8($0)])] != nil }) else { throw LiveFailure.resource }
        ranks = decoded
        regex = try NSRegularExpression(pattern: expression)
    }

    func count(_ text: String) throws -> Int {
        guard text.utf8.count <= 16_384 else { throw LiveFailure.bound }
        let source = text as NSString
        var total = 0, end = 0, budget = 4_000_000
        var failure: Error?
        let deadline = DispatchTime.now().uptimeNanoseconds + 50_000_000
        regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: source.length)) { match, _, stop in
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                failure = LiveFailure.bound; stop.pointee = true; return
            }
            guard let match else { return }
            guard match.range.location == end, match.range.length > 0 else {
                failure = LiveFailure.bound; stop.pointee = true; return
            }
            let bytes = Data(source.substring(with: match.range).utf8)
            guard bytes.count <= 512 else { failure = LiveFailure.bound; stop.pointee = true; return }
            end = NSMaxRange(match.range)
            if ranks[bytes] != nil { total += 1; return }
            var boundaries = Array(0...bytes.count)
            while boundaries.count > 2 {
                var bestRank = Int.max, bestIndex: Int?
                for i in 0..<(boundaries.count - 2) {
                    let span = boundaries[i]..<boundaries[i + 2]
                    budget -= span.count
                    guard budget >= 0 else { failure = LiveFailure.bound; stop.pointee = true; return }
                    if let rank = ranks[bytes.subdata(in: span)], rank < bestRank { bestRank = rank; bestIndex = i + 1 }
                }
                guard let bestIndex else { break }
                boundaries.remove(at: bestIndex)
            }
            total += boundaries.count - 1
        }
        if let failure { throw failure }
        guard end == source.length else { throw LiveFailure.bound }
        return total
    }
}

private enum LiveFailure: Error { case resource, bound }

func observedIdentifier(_ value: Any?) -> String? {
    guard let value = value as? String, !value.isEmpty, value.utf8.count <= 256,
          value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 95].contains($0) }) else { return nil }
    return value
}

// Serial observation queue owns this state. No text or model selection leaves this object.
final class VisibleEstimator {
    struct Key: Hashable { let thread: String; let turn: String; let item: String }
    private struct Item {
        var text = ""
        var count = 0
        var dirty = false
        var received: UInt64
    }
    private struct Mapping: Equatable { let model: String; let provider: String }
    private var mappings: [String: Mapping] = [:]
    private var requests: [String: UInt64] = [:]
    private var selectionRevision: UInt64 = 0
    private var clientObserved = false
    private var invalidated: Set<String> = []
    private var items: [Key: Item] = [:]
    private var seen: Set<Key> = []
    private var turns: [String: String] = [:]
    private var tokenizer: OrdinaryBPE?
    private var loaded = false
    private var lastCalculation: UInt64?
    private(set) var exhausted = false
    private let emit: (String, [String: Any], UInt64) -> Void

    init(emit: @escaping (String, [String: Any], UInt64) -> Void) { self.emit = emit }

    func clear() {
        exhausted = true
        items.removeAll(); seen.removeAll(); turns.removeAll(); mappings.removeAll(); requests.removeAll(); invalidated.removeAll()
    }

    private func unavailable(_ key: Key, _ reason: String, _ time: UInt64) {
        items.removeValue(forKey: key)
        emit(key.thread, ["type": "visible_unavailable", "turn_id": key.turn, "item_id": key.item, "reason": reason], time)
    }

    private func sample(_ key: Key, count: Int, final: Bool, corrected: Bool, mismatch: Bool = false, time: UInt64) {
        guard let mapping = mappings[key.thread] else { unavailable(key, "unsupported_mapping", time); return }
        emit(key.thread, ["type": "visible_count", "turn_id": key.turn, "item_id": key.item,
                          "count": count, "final": final, "corrected": corrected, "text_mismatch": mismatch,
                          "complete_from_start": true, "model": mapping.model, "encoding": "o200k_base"], time)
    }

    private func invalidate(_ thread: String, time: UInt64) {
        mappings.removeValue(forKey: thread)
        for key in Array(items.keys) where key.thread == thread { unavailable(key, "model_changed", time) }
    }

    private func mapping(_ fields: [String: Any], thread: String, time: UInt64) {
        guard clientObserved else { return }
        let next: Mapping?
        if let model = fields["model"] as? String, OrdinaryBPE.models.contains(model),
           let provider = fields["modelProvider"] as? String, provider == "openai" {
            next = Mapping(model: model, provider: provider)
        } else { next = nil }
        if mappings[thread] != next { invalidate(thread, time: time) }
        if mappings.count < 256 || mappings[thread] != nil { mappings[thread] = next }
    }

    private func requestKey(_ value: Any?) -> String? {
        if let string = observedIdentifier(value) { return "s:" + string }
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), let id = Int64(n.stringValue) { return "i:\(id)" }
        return nil
    }

    func observe(_ json: [String: Any], client: Bool, time: UInt64) {
        guard !exhausted else { return }
        let method = json["method"] as? String
        let params = json["params"] as? [String: Any] ?? [:]
        if client {
            clientObserved = true
            if let method, ["thread/start", "thread/resume", "thread/fork"].contains(method), let id = requestKey(json["id"]) {
                guard requests.count < 256 else { exhausted = true; clear(); return }
                requests[id] = selectionRevision
            }
            if let thread = observedIdentifier(params["threadId"]),
               ["turn/start", "thread/settings/update", "thread/resume"].contains(method ?? ""),
               (params["model"] != nil && !(params["model"] is NSNull)) || (params["collaborationMode"] != nil && !(params["collaborationMode"] is NSNull)) {
                // A requested selection is not proof of the effective server model.
                selectionRevision += 1
                guard invalidated.count < 256 || invalidated.contains(thread) else { exhausted = true; clear(); return }
                invalidated.insert(thread)
                invalidate(thread, time: time)
            }
            return
        }
        if method == nil, let id = requestKey(json["id"]), let revision = requests.removeValue(forKey: id), revision == selectionRevision,
           let result = json["result"] as? [String: Any], let thread = result["thread"] as? [String: Any],
           let threadID = observedIdentifier(thread["id"]) {
            invalidated.remove(threadID)
            mapping(result, thread: threadID, time: time)
            return
        }
        guard let method else { return }
        if method == "thread/started", let thread = params["thread"] as? [String: Any], let id = observedIdentifier(thread["id"]) {
            if !invalidated.contains(id) { mapping(thread, thread: id, time: time) }; return
        }
        guard let thread = observedIdentifier(params["threadId"]) else { return }
        if method == "thread/settings/updated", let settings = params["threadSettings"] as? [String: Any] {
            invalidated.remove(thread)
            mapping(settings, thread: thread, time: time); return
        }
        if method == "model/rerouted" {
            guard invalidated.count < 256 || invalidated.contains(thread) else { exhausted = true; clear(); return }
            selectionRevision += 1; invalidated.insert(thread)
            invalidate(thread, time: time); return
        }
        if ["turn/started", "turn/completed"].contains(method), let turn = params["turn"] as? [String: Any], let id = observedIdentifier(turn["id"]) {
            for key in Array(items.keys) where key.thread == thread { unavailable(key, "turn_boundary", time) }
            if method == "turn/started", turns.count < 256 || turns[thread] != nil { turns[thread] = id }
            else { turns.removeValue(forKey: thread) }
            return
        }
        guard ["item/started", "item/completed", "item/agentMessage/delta"].contains(method),
              let turn = observedIdentifier(params["turnId"]) else { return }
        let item = params["item"] as? [String: Any] ?? [:]
        guard method == "item/agentMessage/delta" || item["type"] as? String == "agentMessage",
              let itemID = observedIdentifier(method == "item/agentMessage/delta" ? params["itemId"] : item["id"]) else { return }
        let key = Key(thread: thread, turn: turn, item: itemID)
        if method == "item/started" {
            guard !seen.contains(key) else { unavailable(key, "duplicate_start", time); return }
            guard seen.count < 4096 else { exhausted = true; clear(); return }
            seen.insert(key)
            guard turns[thread] == turn else { unavailable(key, "missing_turn_start", time); return }
            guard mappings[thread] != nil else { unavailable(key, "unsupported_mapping", time); return }
            guard count("") != nil else { unavailable(key, "tokenizer_unavailable", time); return }
            guard items.count < 4 else { unavailable(key, "message_bound", time); return }
            guard let text = item["text"] as? String, text.isEmpty else { unavailable(key, "nonempty_start", time); return }
            items[key] = Item(received: time)
            sample(key, count: 0, final: false, corrected: false, time: time)
            return
        }
        guard var state = items[key] else {
            // Suppress repeated unavailable records, never deduplicate actual deltas.
            if !seen.contains(key) {
                guard seen.count < 4096 else { exhausted = true; clear(); return }
                seen.insert(key); unavailable(key, "missing_item_start", time)
            }
            return
        }
        if method == "item/agentMessage/delta" {
            guard let delta = params["delta"] as? String, state.text.utf8.count + delta.utf8.count <= 16_384 else { unavailable(key, "message_bound", time); return }
            state.text.append(delta); state.dirty = state.dirty || !delta.isEmpty; state.received = time
            items[key] = state
            return
        }
        defer { items.removeValue(forKey: key) }
        guard let finalText = item["text"] as? String, finalText.utf8.count <= 16_384 else { unavailable(key, "message_bound", time); return }
        let mismatch = finalText != state.text
        if mismatch { state.text = finalText; state.dirty = true }
        if state.dirty {
            // Terminal reconciliation is the single exception to active 2 Hz batches.
            lastCalculation = DispatchTime.now().uptimeNanoseconds
            guard let count = count(state.text) else { unavailable(key, loaded && tokenizer == nil ? "tokenizer_unavailable" : "work_bound", time); return }
            sample(key, count: count, final: true, corrected: mismatch || count < state.count, mismatch: mismatch, time: time)
        } else { sample(key, count: state.count, final: true, corrected: mismatch, mismatch: mismatch, time: time) }
    }

    private func canCalculate(_ now: UInt64) -> Bool {
        guard let lastCalculation else { return true }
        return now >= lastCalculation && now - lastCalculation >= 500_000_000
    }

    private func count(_ text: String) -> Int? {
        if !loaded { loaded = true; tokenizer = try? OrdinaryBPE() }
        return try? tokenizer?.count(text)
    }

    func tick(_ now: UInt64) {
        guard !exhausted, canCalculate(now), items.values.contains(where: { $0.dirty }) else { return }
        lastCalculation = now
        for key in Array(items.keys) {
            guard var state = items[key], state.dirty else { continue }
            guard let value = count(state.text) else { unavailable(key, tokenizer == nil ? "tokenizer_unavailable" : "work_bound", now); continue }
            sample(key, count: value, final: false, corrected: value < state.count, time: state.received)
            guard !exhausted else { return }
            state.count = value; state.dirty = false; items[key] = state
        }
    }
}
