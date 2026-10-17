import Foundation
import CodexHubCore

/// Only time and observed deltas survive a restart; live counter anchors never do.
enum UsageHistoryArchive {
    enum Failure: Error { case invalid }
    private struct Point: Codable { let timestamp: Double; let output: Int }
    private struct Entry: Codable { let thread: String; let run: String?; let points: [Point] }
    private struct Archive: Codable { let version: Int; let home: String; let entries: [Entry] }
    static let maximumBytes = 4_194_304

    static func encode(_ history: [ThreadKey: [UsageHistoryPoint]], home: String, monotonic: Double, wall: Double) throws -> Data {
        guard monotonic.isFinite, monotonic >= 0, wall.isFinite else { throw Failure.invalid }
        let entries = history.filter { $0.key.homeID == home }.map { key, points in
            Entry(thread: key.threadID, run: key.runID, points: points.filter {
                $0.time.isFinite && $0.time > monotonic - UsageHistoryPoint.windowSeconds && $0.time <= monotonic && $0.outputTokens > 0
            }.suffix(UsageHistoryPoint.maximumPoints).map { Point(timestamp: wall - (monotonic - $0.time), output: $0.outputTokens) })
        }.filter { !$0.points.isEmpty }
        guard entries.count <= 1000 else { throw Failure.invalid }
        let data = try JSONEncoder().encode(Archive(version: 1, home: home, entries: entries))
        guard data.count <= maximumBytes else { throw Failure.invalid }
        return data
    }

    static func decode(_ data: Data?, home: String, monotonic: Double, wall: Double) throws -> [ThreadKey: [UsageHistoryPoint]] {
        guard let data else { return [:] }
        guard data.count <= maximumBytes, monotonic.isFinite, monotonic >= 0, wall.isFinite else { throw Failure.invalid }
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.version == 1, archive.home == home, archive.entries.count <= 1000 else { throw Failure.invalid }
        var result: [ThreadKey: [UsageHistoryPoint]] = [:]
        var seen: Set<ThreadKey> = []
        for entry in archive.entries {
            guard !entry.thread.isEmpty, entry.thread.utf8.count <= 256, (entry.run?.utf8.count ?? 0) <= 256,
                  entry.points.count <= UsageHistoryPoint.maximumPoints else { throw Failure.invalid }
            let key = ThreadKey(homeID: home, runID: entry.run, threadID: entry.thread)
            guard seen.insert(key).inserted else { throw Failure.invalid }
            var last = -Double.infinity
            var restored: [UsageHistoryPoint] = []
            for point in entry.points {
                guard point.timestamp.isFinite, point.timestamp > last, point.output > 0 else { throw Failure.invalid }
                last = point.timestamp
                let age = wall - point.timestamp
                if age >= 0, age < UsageHistoryPoint.windowSeconds {
                    restored.append(UsageHistoryPoint(time: monotonic - age, outputTokens: point.output))
                }
            }
            if !restored.isEmpty { result[key] = restored }
        }
        return result
    }
}
