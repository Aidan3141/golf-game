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
            session.sendMessage(msg, replyHandler: nil) { _ in
                WCSession.default.transferUserInfo(["env": data])
            }
        } else {
            session.transferUserInfo(msg)
        }
    }

    // fire n forget, only if the phone app is up. dropped ones dont matter, next one is 40ms later
    func send(clubAngle: Double, phase: SwingPhase) {
        guard let session, session.isReachable else { return }
        session.sendMessage(["club": clubAngle, "ph": phase.rawValue], replyHandler: nil, errorHandler: nil)
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
        Task { @MainActor in
            self.lastError = msg
            self.refresh()
        }
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
