import CoreBluetooth
import Foundation
import Observation
import SwingKit

// phone end of the watch -> phone bluetooth fast lane. the phone advertises a tiny service, the
// watch connects + fires 18 byte club packets at it (write w/o response, no ack wait) and pings
// it for clock sync. we ask for the low latency connection interval. watchconnectivity is the
// fallback when this isnt connected
@MainActor
@Observable
final class PhoneBLELink: NSObject {
    private(set) var status = "off"
    private(set) var stats = "—"

    @ObservationIgnored var onClub: ((ClubSample) -> Void)?
    @ObservationIgnored private var pm: CBPeripheralManager?
    @ObservationIgnored private var ch: CBMutableCharacteristic?
    @ObservationIgnored private var inWindow = 0
    @ObservationIgnored private var windowStart = 0.0
    @ObservationIgnored private var ageAvg: Double?

    func start() {
        guard pm == nil else { return }
        pm = CBPeripheralManager(delegate: self, queue: .main, options: nil)
    }

    private func setStatus(_ s: String) {
        if s != status { status = s }
    }

    private func handle(_ data: Data, from central: CBCentral) {
        guard let pkt = ClubPacket.decode(data) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch pkt {
        case .sample(let s):
            if let t = s.time { ageAvg = ageAvg.map { $0 * 0.8 + (now - t) * 0.2 } ?? (now - t) }
            onClub?(s)
            inWindow += 1
            if now - windowStart >= 1 {
                let age = ageAvg.map { String(format: "%.0f ms old", $0 * 1000) } ?? "not synced"
                stats = String(format: "%.0f/s · %@", Double(inWindow) / (now - windowStart), age)
                inWindow = 0
                windowStart = now
            }
        case .ping(let t0):
            // answer right away, the watch measures the round trip
            guard let pm, let ch else { return }
            _ = pm.updateValue(ClubPacket.pong(t0: t0, t1: now).encoded(), for: ch, onSubscribedCentrals: [central])
        case .pong:
            break
        }
    }
}

// isolated conformance: the manager delivers on .main so these run on the main actor
extension PhoneBLELink: @MainActor CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        switch p.state {
        case .poweredOn:
            let c = CBMutableCharacteristic(
                type: CBUUID(string: ClubLinkIDs.characteristic),
                properties: [.writeWithoutResponse, .notify],
                value: nil,
                permissions: [.writeable]
            )
            let s = CBMutableService(type: CBUUID(string: ClubLinkIDs.service), primary: true)
            s.characteristics = [c]
            ch = c
            p.removeAllServices()
            p.add(s)
            p.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [s.uuid], CBAdvertisementDataLocalNameKey: "GolfGame"])
            setStatus("waiting for watch")
        case .unauthorized:
            setStatus("bluetooth not allowed")
        case .unsupported:
            setStatus("not supported")
        case .poweredOff:
            setStatus("bluetooth off")
        default:
            setStatus("…")
        }
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        // shortest connection interval the system will give us = least lag per packet
        p.setDesiredConnectionLatency(.low, for: central)
        setStatus("✅ connected")
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        setStatus("waiting for watch")
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // write w/o response, nothing to respond to
        for r in requests {
            if let v = r.value { handle(v, from: r.central) }
        }
    }
}
