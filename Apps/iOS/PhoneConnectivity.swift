import Foundation
import Observation
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

    override init() {
        super.init()
        session?.delegate = self
        session?.activate()
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
