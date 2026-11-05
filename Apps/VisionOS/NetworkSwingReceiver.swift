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
    private(set) var lastLatency: Double?  // phone send -> here, secs

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

    private func handle(_ env: MessageEnvelope) {
        guard env.version == MessageEnvelope.currentVersion else { return }
        switch env.payload {
        case .swing(let s):
            received += 1
            lastLatency = Date.now.timeIntervalSince(env.sentAt)
            continuation.yield(s)
        case .hello(let name):
            state = .connected(name)
        case .ping:
            break
        }
    }
}
