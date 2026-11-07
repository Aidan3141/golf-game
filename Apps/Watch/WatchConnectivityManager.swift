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
    // phone clock - watch clock (both systemUptime), from the reply timestamps
    @ObservationIgnored private(set) var clock = ClockOffsetEstimator()
    @ObservationIgnored private var pingTask: Task<Void, Never>?
    // bluetooth fast lane straight to the phone, used for club samples whenever its connected
    let ble = WatchBLELink()
    @ObservationIgnored private var bleInWindow = 0
    @ObservationIgnored private let session: WCSession? = WCSession.isSupported() ? .default : nil

    override init() {
        super.init()
        session?.delegate = self
        session?.activate()
        ble.onPong = { [weak self] t0, t1, t3 in
            self?.clock.add(sent: t0, remote: t1, received: t3)
        }
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

    // small + fast. sendMessage if the phone app is up, otherwise queue it.
    // "it" = impact time in the phones clock so the headset can line the ball up w/ it
    func send(swing: SwingResult, impactUptime: Double) {
        let it = clock.toRemote(impactUptime)
        // fast lane: tiny impact packet so the ball can go right away, full swing follows below
        if ble.connected { ble.sendImpact(QuickImpact(swing, time: it)) }
        guard let session, let data = try? MessageEnvelope(payload: .swing(swing)).encoded() else { return }
        var msg: [String: Any] = ["env": data]
        if let it { msg["it"] = it }
        if session.isReachable {
            // @Sendable = not main actor. wc calls this on a background queue and a main actor
            // closure there trips swift 6's isolation check + crashes the app
            // capture only sendable bits (Data, Double?), rebuild the dict in there
            session.sendMessage(msg, replyHandler: nil) { @Sendable _ in
                var backup: [String: Any] = ["env": data]
                if let it { backup["it"] = it }
                WCSession.default.transferUserInfo(backup)
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
    // skip this sample, the next fresh one goes instead. so a queue can never build up
    // (fire n forget at 25hz piled up + showed up ~90s late).
    // sample time goes over in the PHONES clock ("st"), the reply carries the phones time ("t1")
    // so every club msg is also a clock sync round trip
    func send(club s: ClubSample) {
        let now = ProcessInfo.processInfo.systemUptime
        // fast lane first: no ack gate needed, the radio only ever sends the newest
        if ble.connected {
            var phoneTime = s
            phoneTime.time = s.time.flatMap { clock.toRemote($0) }
            if ble.send(phoneTime) {
                bleInWindow += 1
                updateStats(now)
                return
            }
        }
        guard let session, session.isReachable else { return }
        if let since = inFlightSince, now - since < 0.5 {
            skipped += 1
            return
        }
        inFlightSince = now
        sentCount += 1
        sentInWindow += 1
        var msg: [String: Any] = ["c": s.angle, "w": s.omega, "ph": s.phase.rawValue, "t0": now]
        if let t = s.time, let st = clock.toRemote(t) { msg["st"] = st }
        // both run on a wc background queue -> must be @Sendable (nonisolated), not main actor.
        // without it the first reply crashed the watch (dispatch_assert_queue_fail)
        session.sendMessage(msg, replyHandler: { @Sendable reply in
            let t3 = ProcessInfo.processInfo.systemUptime
            let t1 = reply["t1"] as? Double
            Task { @MainActor in self.acked(t0: now, t1: t1, t3: t3) }
        }, errorHandler: { @Sendable _ in
            Task { @MainActor in self.inFlightSince = nil }
        })
        updateStats(now)
    }

    private func acked(t0: Double, t1: Double?, t3: Double) {
        let rtt = t3 - t0
        rttAvg = rttAvg.map { $0 * 0.8 + rtt * 0.2 } ?? rtt
        if let t1 { clock.add(sent: t0, remote: t1, received: t3) }
        inFlightSince = nil
    }

    // keep the clock sync warm before the first swing (club msgs only flow once ur addressed)
    func startClockPings() {
        guard pingTask == nil else { return }
        pingTask = Task {
            while !Task.isCancelled {
                if let session, session.isReachable, inFlightSince == nil {
                    let t0 = ProcessInfo.processInfo.systemUptime
                    session.sendMessage(["ping": t0], replyHandler: { @Sendable reply in
                        let t3 = ProcessInfo.processInfo.systemUptime
                        let t1 = reply["t1"] as? Double
                        Task { @MainActor in
                            if let t1 { self.clock.add(sent: t0, remote: t1, received: t3) }
                        }
                    }, errorHandler: { @Sendable _ in })
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopClockPings() {
        pingTask?.cancel()
        pingTask = nil
    }

    func startFastLane() { ble.start() }
    func stopFastLane() { ble.stop() }

    private func updateStats(_ now: Double) {
        guard now - statsWindowStart >= 1 else { return }
        let sync = clock.uncertainty.map { String(format: "±%.0fms", $0 * 1000) } ?? "no sync"
        if bleInWindow > 0 {
            let rate = Double(bleInWindow) / (now - statsWindowStart)
            clubStats = String(format: "ble %.0f/s · %@", rate, sync)
        } else {
            let rate = Double(sentInWindow) / (now - statsWindowStart)
            clubStats = String(format: "wc %.0f/s · rtt %.0fms · %@", rate, (rttAvg ?? 0) * 1000, sync)
        }
        statsWindowStart = now
        sentInWindow = 0
        bleInWindow = 0
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
