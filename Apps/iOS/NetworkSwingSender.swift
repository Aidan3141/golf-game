import Foundation
import Network
import Observation
import SwingKit
import UIKit

// phone side: finds the avp over bonjour/peer to peer, keeps one connection open, sends envelopes
@MainActor
@Observable
final class NetworkSwingSender {
    private(set) var state = LinkState.off
    private(set) var sent = 0
    private(set) var mode = SwingMode.full
    @ObservationIgnored var onMode: ((SwingMode) -> Void)?
    @ObservationIgnored private var decoder = FrameDecoder()

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var endpoint: NWEndpoint?
    @ObservationIgnored private var pingTask: Task<Void, Never>?
    // headset clock - phone clock (both uptime), from clock ping/pongs
    @ObservationIgnored private(set) var clock = ClockOffsetEstimator()
    private(set) var syncLabel = "—"

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: SwingLink.serviceType, domain: nil), using: SwingLink.parameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.found(results) }
        }
        b.stateUpdateHandler = { [weak self] s in
            MainActor.assumeIsolated {
                if case .failed(let e) = s { self?.state = .failed(e.localizedDescription) }
            }
        }
        b.start(queue: .main)
        browser = b
        state = .searching
    }

    func stop() {
        pingTask?.cancel()
        connection?.cancel()
        browser?.cancel()
        connection = nil
        browser = nil
        state = .off
    }

    func send(_ swing: SwingResult) {
        send(MessageEnvelope(payload: .swing(swing)))
    }

    // sample time comes in phone clock, goes out in the headsets clock
    func send(club s: ClubSample) {
        send(MessageEnvelope(payload: .clubSample(s.shifted(by: clock.offset))))
    }

    // impact time phone clock -> headset clock so the ball can launch from the real impact moment
    func send(_ swing: SwingResult, impactPhoneTime: Double?) {
        let it = impactPhoneTime.flatMap { clock.toRemote($0) }
        send(MessageEnvelope(payload: .swingAt(swing, impactTime: it)))
    }

    private func send(_ env: MessageEnvelope) {
        guard let connection, state.isConnected, let data = try? MessageFramer.frame(env) else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                guard error == nil else { return }
                switch env.payload {
                case .swing, .swingAt: self?.sent += 1
                default: break
                }
            }
        })
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        guard connection == nil, let first = results.first else { return }
        connect(to: first.endpoint)
    }

    private func connect(to ep: NWEndpoint) {
        endpoint = ep
        let c = NWConnection(to: ep, using: SwingLink.parameters())
        connection = c
        c.stateUpdateHandler = { [weak self, weak c] s in
            MainActor.assumeIsolated {
                guard let self, let c, c === self.connection else { return }
                switch s {
                case .ready:
                    self.state = .connected("Vision Pro")
                    self.decoder = FrameDecoder()
                    self.clock.reset()  // new connection, maybe a new headset boot
                    self.send(MessageEnvelope(payload: .hello(device: UIDevice.current.name)))
                    self.startPings()
                    self.receive(on: c)
                case .failed, .cancelled:
                    self.connection = nil
                    self.pingTask?.cancel()
                    self.state = .searching
                    self.retry()
                case .waiting:
                    // usually no route yet, kick it
                    c.restart()
                default:
                    break
                }
            }
        }
        c.start(queue: .main)
    }

    // avp talks back: mode + clock pongs
    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty {
                    for env in self.decoder.append(data) {
                        switch env.payload {
                        case .mode(let m):
                            self.mode = m
                            self.onMode?(m)
                        case .clockPong(let t0, let t1):
                            self.clock.add(sent: t0, remote: t1, received: ProcessInfo.processInfo.systemUptime)
                            let label = self.clock.uncertainty.map { String(format: "±%.0f ms", $0 * 1000) } ?? "—"
                            if label != self.syncLabel { self.syncLabel = label }
                        default:
                            break
                        }
                    }
                }
                if !done && error == nil { self.receive(on: c) }
            }
        }
    }

    private func retry() {
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard self.connection == nil, self.browser != nil else { return }
            if let r = self.browser?.browseResults.first {
                self.connect(to: r.endpoint)
            }
        }
    }

    // clock ping every sec: keeps the link warm, notices when the headset goes away, + keeps
    // the phone<->headset clock offset fresh. first few go fast so we're synced right away
    private func startPings() {
        pingTask?.cancel()
        pingTask = Task {
            var n = 0
            while !Task.isCancelled {
                self.send(MessageEnvelope(payload: .clockPing(t0: ProcessInfo.processInfo.systemUptime)))
                n += 1
                try? await Task.sleep(for: .milliseconds(n < 10 ? 150 : 1000))
            }
        }
    }
}
