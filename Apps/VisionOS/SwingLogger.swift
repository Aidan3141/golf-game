import Foundation
import SwingKit

// per frame club debug data. keeps ~8s in memory, ~1s after a swing it writes the last 5s
// to Documents/SwingLogs/*.json (visible in the Files app + shareable from the window)
// so we can see exactly what the club did vs ur hands + the watch, frame by frame
@MainActor
final class SwingLogger {
    struct Frame: Codable {
        var t: Double  // headset uptime
        var src: String  // anchored / manual / fallback / frozen / none
        var lead: Bool  // lead hand tracked this frame
        var trail: Bool
        var grip: [Float]?  // where the club grip was drawn (world)
        var head: [Float]?  // clubhead (world)
        var watch: Double?  // raw last watch angle (rad)
        var shown: Double?  // watch angle we drew after prediction (rad)
        var age: Double?  // how old the newest watch sample was (s)
        var phase: String
    }

    struct Log: Codable {
        var version = 1
        var createdAt: Date
        var reason: String
        var settings: [String: String]
        var frames: [Frame]
    }

    static let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appending(path: "SwingLogs", directoryHint: .isDirectory)

    private var ring: [Frame] = []
    private var dumpAt: Double?
    private var reason = ""
    var settings: (() -> [String: String])?
    var onWrite: ((URL) -> Void)?

    func record(_ f: Frame) {
        ring.append(f)
        if ring.count > 720 { ring.removeFirst(ring.count - 720) }  // ~8s at 90fps
        if let d = dumpAt, f.t >= d {
            dumpAt = nil
            write(until: f.t)
        }
    }

    // a swing happened, write the log a bit later so the follow thru is in it
    func mark(_ why: String, delay: Double = 1.2) {
        guard dumpAt == nil else { return }
        reason = why
        dumpAt = ProcessInfo.processInfo.systemUptime + delay
    }

    private func write(until end: Double) {
        let frames = ring.filter { $0.t >= end - 5 }
        guard let first = frames.first else { return }
        let rel = frames.map { f -> Frame in
            var f = f
            f.t = ((f.t - first.t) * 1000).rounded() / 1000
            return f
        }
        let log = Log(createdAt: .now, reason: reason, settings: settings?() ?? [:], frames: rel)
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            let url = Self.directory.appending(path: "swinglog-\(f.string(from: .now)).json")
            let e = JSONEncoder()
            e.dateEncodingStrategy = .iso8601
            try e.encode(log).write(to: url)
            prune()
            onWrite?(url)
        } catch {
            // debug only, dont care
        }
    }

    // keep the newest 20
    private func prune() {
        let urls = Self.all()
        guard urls.count > 20 else { return }
        for u in urls.dropFirst(20) { try? FileManager.default.removeItem(at: u) }
    }

    static func all() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
