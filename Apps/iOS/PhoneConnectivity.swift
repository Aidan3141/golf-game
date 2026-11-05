import Foundation
import Observation
import SwingKit
import WatchConnectivity

// gets recording files from the watch. file has to be moved before the delegate returns or its gone
@MainActor
@Observable
final class PhoneConnectivity: NSObject {
    private(set) var isPaired = false
    private(set) var isWatchAppInstalled = false
    private(set) var isReachable = false
    private(set) var receivedCount = 0

    @ObservationIgnored private let session: WCSession? = WCSession.isSupported() ? .default : nil
    @ObservationIgnored var onReceive: (() -> Void)?
    @ObservationIgnored var onSwing: ((SwingResult, Date) -> Void)?  // swing + when watch sent it
    @ObservationIgnored var onClub: ((Double, SwingPhase, Date) -> Void)?  // live club angle + when the watch sent it
    private(set) var clubStats = "—"
    @ObservationIgnored private var clubInWindow = 0
    @ObservationIgnored private var clubWindowStart = 0.0
    @ObservationIgnored private var clubAgeAvg: Double?

    override init() {
        super.init()
        session?.delegate = self
        session?.activate()
    }

    // context sticks around so the watch gets it even if it wasnt open
    func send(mode: SwingMode) {
        guard let session, session.activationState == .activated else { return }
        try? session.updateApplicationContext(["mode": mode.rawValue])
        if session.isReachable {
            session.sendMessage(["mode": mode.rawValue], replyHandler: nil, errorHandler: nil)
        }
    }

    private func clubArrived(_ sentAt: Date) {
        let age = Date.now.timeIntervalSince(sentAt)
        clubAgeAvg = clubAgeAvg.map { $0 * 0.8 + age * 0.2 } ?? age
        clubInWindow += 1
        let now = ProcessInfo.processInfo.systemUptime
        if now - clubWindowStart >= 1 {
            clubStats = String(format: "%.0f/s · %.0f ms old", Double(clubInWindow) / (now - clubWindowStart), (clubAgeAvg ?? 0) * 1000)
            clubWindowStart = now
            clubInWindow = 0
        }
    }

    private func refresh() {
        guard let session, session.activationState == .activated else { return }
        isPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isReachable = session.isReachable
    }
}

extension PhoneConnectivity: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in self.refresh() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // watch switch, reactivate for the new one
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.refresh() }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.refresh() }
    }

    // swings come as ["env": envelope json]. sendMessage when reachable, userInfo as backup
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    // club msgs want a reply, thats the watchs ack gate. reply first, then do stuff
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler([:])
        handle(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handle(userInfo)
    }

    nonisolated private func handle(_ dict: [String: Any]) {
        if let angle = dict["club"] as? Double {
            let phase = (dict["ph"] as? String).flatMap(SwingPhase.init(rawValue:)) ?? .idle
            let sentAt = (dict["ts"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? .now
            Task { @MainActor in
                self.clubArrived(sentAt)
                self.onClub?(angle, phase, sentAt)
            }
            return
        }
        guard let data = dict["env"] as? Data,
              let env = try? MessageEnvelope.decode(data),
              case .swing(let swing) = env.payload else { return }
        let sentAt = env.sentAt
        Task { @MainActor in
            self.isReachable = true
            self.onSwing?(swing, sentAt)
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // move now, sync. temp file gets deleted after we return
        let name = file.fileURL.lastPathComponent
        let dest = RecordingStore.directory.appending(path: name)
        do {
            try FileManager.default.createDirectory(at: RecordingStore.directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path()) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: file.fileURL, to: dest)
        } catch {
            return
        }
        Task { @MainActor in
            self.receivedCount += 1
            self.onReceive?()
        }
    }
}
