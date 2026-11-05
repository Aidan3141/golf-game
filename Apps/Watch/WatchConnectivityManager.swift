import Foundation
import Observation
import SwingKit
import WatchConnectivity

// sends recording files to the phone. transferFile queues + retries on its own
@MainActor
@Observable
final class WatchConnectivityManager: NSObject {
    private(set) var isReachable = false
    private(set) var pendingTransfers = 0
    private(set) var lastError: String?

    @ObservationIgnored var onMode: ((SwingMode) -> Void)?
    @ObservationIgnored private let session: WCSession? = WCSession.isSupported() ? .default : nil

    override init() {
        super.init()
        session?.delegate = self
        session?.activate()
    }

    func send(_ rec: SwingRecording) {
        guard let session else { return }
        do {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appending(path: "outbox", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appending(path: rec.fileName)
            try rec.encoded().write(to: url)
            session.transferFile(url, metadata: ["kind": "recording", "version": SwingRecording.currentVersion])
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // small + fast. sendMessage if the phone app is up, otherwise queue it
    func send(swing: SwingResult) {
        guard let session, let data = try? MessageEnvelope(payload: .swing(swing)).encoded() else { return }
        let msg: [String: Any] = ["env": data]
        if session.isReachable {
            // @Sendable = not main actor. wc calls this on a background queue and a main actor
            // closure there trips swift 6's isolation check + crashes the app
            session.sendMessage(msg, replyHandler: nil) { @Sendable _ in
                WCSession.default.transferUserInfo(["env": data])
            }
        } else {
            session.transferUserInfo(msg)
        }
    }

    // club stream debug numbers, refreshed ~1/s so the ui doesnt redraw at 30hz
    private(set) var clubStats = "—"
    @ObservationIgnored private var inFlightSince: Double?
    @ObservationIgnored private var sentCount = 0
    @ObservationIgnored private var skipped = 0
    @ObservationIgnored private var rttAvg: Double?
    @ObservationIgnored private var statsWindowStart = 0.0
    @ObservationIgnored private var sentInWindow = 0

    // ack gated: only one club msg in the air at a time. if the last one hasnt come back we
    // skip this angle, the next fresh one goes instead. so a queue can never build up
    // (fire n forget at 25hz piled up + showed up ~90s late)
    func send(clubAngle: Double, phase: SwingPhase) {
        guard let session, session.isReachable else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let since = inFlightSince, now - since < 0.5 {
            skipped += 1
            return
        }
        inFlightSince = now
        sentCount += 1
        sentInWindow += 1
        let msg: [String: Any] = [
            "club": clubAngle, "ph": phase.rawValue,
            "ts": Date.now.timeIntervalSince1970, "seq": sentCount,
        ]
        // both run on a wc background queue -> must be @Sendable (nonisolated), not main actor.
        // without it the first reply crashed the watch (dispatch_assert_queue_fail)
        session.sendMessage(msg, replyHandler: { @Sendable _ in
            Task { @MainActor in self.acked(sentAt: now) }
        }, errorHandler: { @Sendable _ in
            Task { @MainActor in self.inFlightSince = nil }
        })
        updateStats(now)
    }

    private func acked(sentAt: Double) {
        let rtt = ProcessInfo.processInfo.systemUptime - sentAt
        rttAvg = rttAvg.map { $0 * 0.8 + rtt * 0.2 } ?? rtt
        inFlightSince = nil
    }

    private func updateStats(_ now: Double) {
        guard now - statsWindowStart >= 1 else { return }
        let rate = Double(sentInWindow) / (now - statsWindowStart)
        clubStats = String(format: "club %.0f/s · rtt %.0fms · skip %d", rate, (rttAvg ?? 0) * 1000, skipped)
        statsWindowStart = now
        sentInWindow = 0
    }

    private func refresh() {
        guard let session else { return }
        isReachable = session.isReachable
        pendingTransfers = session.outstandingFileTransfers.count
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
        let msg = error?.localizedDescription
        let ctx = session.receivedApplicationContext
        Task { @MainActor in
            self.lastError = msg
            self.refresh()
        }
        handleMode(ctx)
    }

    // avp switched spaces -> phone tells us. context survives if we werent running
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext ctx: [String: Any]) {
        handleMode(ctx)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleMode(message)
    }

    nonisolated private func handleMode(_ dict: [String: Any]) {
        guard let raw = dict["mode"] as? String, let mode = SwingMode(rawValue: raw) else { return }
        Task { @MainActor in self.onMode?(mode) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.refresh() }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        // sent ok -> delete the local copy
        if error == nil {
            try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        }
        let msg = error?.localizedDescription
        Task { @MainActor in
            if let msg { self.lastError = msg }
            self.refresh()
            // count updates a beat after the callback
            try? await Task.sleep(for: .milliseconds(300))
            self.refresh()
        }
    }
}
