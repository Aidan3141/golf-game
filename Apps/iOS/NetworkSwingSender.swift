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

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var endpoint: NWEndpoint?
    @ObservationIgnored private var pingTask: Task<Void, Never>?

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

    private func send(_ env: MessageEnvelope) {
        guard let connection, state.isConnected, let data = try? MessageFramer.frame(env) else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                if error == nil, case .swing = env.payload { self?.sent += 1 }
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
                    self.send(MessageEnvelope(payload: .hello(device: UIDevice.current.name)))
                    self.startPings()
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

    private func retry() {
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard self.connection == nil, self.browser != nil else { return }
            if let r = self.browser?.browseResults.first {
                self.connect(to: r.endpoint)
            }
        }
    }

    // keeps the link warm + notices when the headset goes away
    private func startPings() {
        pingTask?.cancel()
        pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self.send(MessageEnvelope(payload: .ping))
            }
        }
    }
}
