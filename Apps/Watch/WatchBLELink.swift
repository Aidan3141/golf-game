import CoreBluetooth
import Foundation
import Observation
import SwingKit

// watch end of the bluetooth fast lane: finds the phones GolfGame service, connects, writes club
// packets w/o waiting for acks (no queue can build, the radio just sends the newest) + pings
// every 0.5s for clock sync. watchconnectivity stays the fallback
@MainActor
@Observable
final class WatchBLELink: NSObject {
    private(set) var connected = false
    private(set) var status = "off"

    // ping round trips -> the shared watch<->phone clock estimator
    @ObservationIgnored var onPong: ((Double, Double, Double) -> Void)?
    @ObservationIgnored private var cm: CBCentralManager?
    @ObservationIgnored private var peer: CBPeripheral?
    @ObservationIgnored private var ch: CBCharacteristic?
    @ObservationIgnored private var pingTask: Task<Void, Never>?
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private(set) var sentCount = 0
    @ObservationIgnored private(set) var dropped = 0

    func start() {
        wanted = true
        if cm == nil {
            cm = CBCentralManager(delegate: self, queue: .main, options: nil)
        } else {
            scan()
        }
    }

    func stop() {
        wanted = false
        pingTask?.cancel()
        pingTask = nil
        if let cm {
            cm.stopScan()
            if let peer { cm.cancelPeripheralConnection(peer) }
        }
        peer = nil
        ch = nil
        setConnected(false)
        setStatus("off")
    }

    // sample time must already be in the phones clock (or nil)
    @discardableResult
    func send(_ s: ClubSample) -> Bool {
        guard connected, let peer, let ch else { return false }
        guard peer.canSendWriteWithoutResponse else {
            dropped += 1  // radio busy, skip this one, newest wins
            return true
        }
        peer.writeValue(ClubPacket.sample(s).encoded(), for: ch, type: .withoutResponse)
        sentCount += 1
        return true
    }

    // impact matters more than any one club sample: if the radio is busy, retry for ~50ms
    func sendImpact(_ q: QuickImpact) {
        guard connected, peer != nil, ch != nil else { return }
        let data = ClubPacket.impact(q).encoded()
        Task {
            for _ in 0..<10 {
                if let peer, let ch, peer.canSendWriteWithoutResponse {
                    peer.writeValue(data, for: ch, type: .withoutResponse)
                    return
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    private func scan() {
        guard wanted, let cm, cm.state == .poweredOn, peer == nil else { return }
        cm.scanForPeripherals(withServices: [CBUUID(string: ClubLinkIDs.service)], options: nil)
        setStatus("looking for phone")
    }

    private func startPings() {
        pingTask?.cancel()
        pingTask = Task {
            while !Task.isCancelled {
                if let peer, let ch, connected, peer.canSendWriteWithoutResponse {
                    peer.writeValue(ClubPacket.ping(t0: ProcessInfo.processInfo.systemUptime).encoded(), for: ch, type: .withoutResponse)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func setConnected(_ c: Bool) {
        if c != connected { connected = c }
    }

    private func setStatus(_ s: String) {
        if s != status { status = s }
    }
}

// isolated conformance: the managers deliver on .main so these run on the main actor
extension WatchBLELink: @MainActor CBCentralManagerDelegate, @MainActor CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: scan()
        case .unauthorized: setStatus("bluetooth not allowed")
        case .unsupported: setStatus("not supported")
        default: setStatus("bluetooth off")
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peer == nil else { return }
        peer = p
        c.stopScan()
        c.connect(p, options: nil)
        setStatus("connecting")
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.delegate = self
        p.discoverServices([CBUUID(string: ClubLinkIDs.service)])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: (any Error)?) {
        lost()
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: (any Error)?) {
        lost()
    }

    private func lost() {
        pingTask?.cancel()
        peer = nil
        ch = nil
        setConnected(false)
        // try again in a sec
        Task {
            try? await Task.sleep(for: .seconds(1))
            self.scan()
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: (any Error)?) {
        for s in p.services ?? [] where s.uuid == CBUUID(string: ClubLinkIDs.service) {
            p.discoverCharacteristics([CBUUID(string: ClubLinkIDs.characteristic)], for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: (any Error)?) {
        guard let c = s.characteristics?.first(where: { $0.uuid == CBUUID(string: ClubLinkIDs.characteristic) }) else { return }
        ch = c
        p.setNotifyValue(true, for: c)  // pongs come back as notifications
        setConnected(true)
        setStatus("✅ bluetooth")
        startPings()
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: (any Error)?) {
        let t3 = ProcessInfo.processInfo.systemUptime
        guard let v = c.value, case .pong(let t0, let t1)? = ClubPacket.decode(v) else { return }
        onPong?(t0, t1, t3)
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {}
}
