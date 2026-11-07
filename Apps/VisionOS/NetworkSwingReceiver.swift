import Foundation
import Network
import Observation
import SwingKit

// avp side: advertises over bonjour, takes one phone connection at a time, yields swings
@MainActor
@Observable
final class NetworkSwingReceiver: SwingSource {
    private(set) var state = LinkState.off
    private(set) var received = 0
    private(set) var lastLatency: Double?  // impact (or phone send) -> here, secs

    // live club sample, time already in this headsets uptime clock (phone converts it)
    @ObservationIgnored var onClub: ((ClubSample) -> Void)?
    @ObservationIgnored var onQuickImpact: ((QuickImpact) -> Void)?
    // live club debug, refreshed ~1/s
    private(set) var clubStats = "—"
    @ObservationIgnored private var clubWindowStart = 0.0
    @ObservationIgnored private var clubInWindow = 0
    @ObservationIgnored private var clubDropped = 0
    @ObservationIgnored private var ageAvg: Double?
    @ObservationIgnored private(set) var lastClubAge: Double?
    // impact moments (headset uptime) for swings that came w/ one, so the ball can launch from it
    @ObservationIgnored private var impactTimes: [UUID: Double] = [:]
    static let maxClubAge = 0.5  // older than this its not worth drawing
    // tell the phone (-> watch) what kind of swing to look for. resent on every new connection
    @ObservationIgnored var mode = SwingMode.full {
        didSet { if mode != oldValue { sendMode() } }
    }
    private(set) var clubUpdates = 0  // only bumped every 25 msgs so the window doesnt redraw at 25hz
    @ObservationIgnored private var clubCount = 0

    let swings: AsyncStream<SwingResult>
    @ObservationIgnored private let continuation: AsyncStream<SwingResult>.Continuation
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var decoder = FrameDecoder()

    init() {
        (swings, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    func start() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: SwingLink.parameters())
            l.service = NWListener.Service(name: SwingLink.serviceName, type: SwingLink.serviceType)
            l.stateUpdateHandler = { [weak self] s in
                MainActor.assumeIsolated { self?.listenerChanged(s) }
            }
            l.newConnectionHandler = { [weak self] c in
                MainActor.assumeIsolated { self?.accept(c) }
            }
            l.start(queue: .main)
            listener = l
            state = .searching
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        connection?.cancel()
        listener?.cancel()
        connection = nil
        listener = nil
        state = .off
    }

    private func listenerChanged(_ s: NWListener.State) {
        switch s {
        case .failed(let e):
            state = .failed(e.localizedDescription)
            // try again in a sec
            listener?.cancel()
            listener = nil
            Task {
                try? await Task.sleep(for: .seconds(1))
                self.start()
            }
        case .ready where connection == nil:
            state = .searching
        default:
            break
        }
    }

    // newest phone wins
    private func accept(_ c: NWConnection) {
        connection?.cancel()
        connection = c
        decoder = FrameDecoder()
        c.stateUpdateHandler = { [weak self, weak c] s in
            MainActor.assumeIsolated {
                guard let self, let c, c === self.connection else { return }
                switch s {
                case .ready:
                    self.state = .connected("iPhone")
                    self.receive(on: c)
                    self.sendMode()
                case .failed, .cancelled:
                    self.connection = nil
                    self.state = .searching
                default:
                    break
                }
            }
        }
        c.start(queue: .main)
    }

    private func sendMode() {
        send(MessageEnvelope(payload: .mode(mode)))
    }

    private func send(_ env: MessageEnvelope) {
        guard let connection, let data = try? MessageFramer.frame(env) else { return }
        connection.send(content: data, completion: .idempotent)
    }

    func impactTime(for swing: UUID) -> Double? {
        impactTimes[swing]
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty {
                    for env in self.decoder.append(data) {
                        self.handle(env)
                    }
                }
                if done || error != nil {
                    c.cancel()
                } else {
                    self.receive(on: c)
                }
            }
        }
    }

    // synced clocks so age is real: watch sample -> drawable here
    private func clubArrived(_ sample: ClubSample) {
        clubCount &+= 1
        if clubCount % 25 == 1 { clubUpdates = clubCount }
        let now = ProcessInfo.processInfo.systemUptime
        if let t = sample.time {
            let age = now - t
            lastClubAge = age
            ageAvg = ageAvg.map { $0 * 0.8 + age * 0.2 } ?? age
            if age > Self.maxClubAge {
                clubDropped += 1  // stale, drawing it would just be lag
            } else {
                onClub?(sample)
            }
        } else {
            onClub?(sample)  // not synced yet, still better than nothing
        }
        clubInWindow += 1
        if now - clubWindowStart >= 1 {
            let age = ageAvg.map { String(format: "%.0f ms old", $0 * 1000) } ?? "not synced"
            clubStats = String(format: "%.0f/s · %@ · %d stale", Double(clubInWindow) / (now - clubWindowStart), age, clubDropped)
            clubWindowStart = now
            clubInWindow = 0
        }
    }

    private func handle(_ env: MessageEnvelope) {
        guard env.version == MessageEnvelope.currentVersion else { return }
        switch env.payload {
        case .swing(let s):
            received += 1
            lastLatency = Date.now.timeIntervalSince(env.sentAt)
            continuation.yield(s)
        case .swingAt(let s, let impact):
            received += 1
            if let impact {
                impactTimes[s.id] = impact
                if impactTimes.count > 20 { impactTimes.removeAll() }
                lastLatency = ProcessInfo.processInfo.systemUptime - impact
            }
            continuation.yield(s)
        case .hello(let name):
            state = .connected(name)
        case .clockPing(let t0):
            // answer right away, the phone measures the round trip
            send(MessageEnvelope(payload: .clockPong(t0: t0, t1: ProcessInfo.processInfo.systemUptime)))
        case .clubSample(let sample):
            clubArrived(sample)
        case .quickImpact(let q):
            if let t = q.time { lastLatency = ProcessInfo.processInfo.systemUptime - t }
            onQuickImpact?(q)
        case .ping, .mode, .clockPong:
            break
        }
    }
}
