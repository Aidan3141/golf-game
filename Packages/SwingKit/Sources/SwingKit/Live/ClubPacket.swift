import Foundation

// ble ids for the watch -> phone fast lane (phone = peripheral, watch = central).
// the headset + watch can only be ble centrals so they cant link up directly
public enum ClubLinkIDs {
    public static let service = "45B7371E-1ED8-41D7-AA83-81E6987B635A"
    public static let characteristic = "F9D2DE73-D68C-4B86-AA17-C4C886FD0F8B"  // write w/o response + notify
}

// tiny binary packets for the watch -> phone bluetooth fast lane. kept <= 20 bytes so they
// fit the default ble att mtu w/o any negotiation. little endian
public enum ClubPacket: Equatable, Sendable {
    case sample(ClubSample)  // time = sender clock, or receiver clock if `synced`
    case ping(t0: Double)
    case pong(t0: Double, t1: Double)
    case impact(QuickImpact)  // time = sender clock, or receiver clock if synced

    static let sampleType: UInt8 = 1
    static let pingType: UInt8 = 2
    static let pongType: UInt8 = 3
    static let impactType: UInt8 = 4
    static let noFace: Int8 = .min
    static let syncedBit: UInt8 = 0x80

    public func encoded() -> Data {
        var d = Data()
        switch self {
        case .sample(let s):
            d.append(Self.sampleType)
            let phaseIndex = UInt8(SwingPhase.allCases.firstIndex(of: s.phase) ?? 0)
            d.append(phaseIndex | (s.time != nil ? Self.syncedBit : 0))
            d.appendLE(Float(s.angle))
            d.appendLE(Float(s.omega))
            d.appendLE(s.time ?? 0)
        case .ping(let t0):
            d.append(Self.pingType)
            d.appendLE(t0)
        case .pong(let t0, let t1):
            d.append(Self.pongType)
            d.appendLE(t0)
            d.appendLE(t1)
        case .impact(let q):
            // 19 bytes: type, flags, time f64, wrist f32, back ms u16, down ms u16, face deg i8
            d.append(Self.impactType)
            d.append(UInt8(min(max(q.confidence, 0), 1) * 100) | (q.time != nil ? Self.syncedBit : 0))
            d.appendLE(q.time ?? 0)
            d.appendLE(Float(q.wristSpeed))
            d.appendLE(UInt16(min(max(q.backswing * 1000, 0), 65535)))
            d.appendLE(UInt16(min(max(q.downswing * 1000, 0), 65535)))
            let face = q.faceAngle.map { Int8(min(max($0.rounded(), -127), 127)) } ?? Self.noFace
            d.append(UInt8(bitPattern: face))
        }
        return d
    }

    public static func decode(_ data: Data) -> ClubPacket? {
        let b = [UInt8](data)
        guard let type = b.first else { return nil }
        switch type {
        case sampleType:
            guard b.count >= 18 else { return nil }
            let phases = SwingPhase.allCases
            let idx = Int(b[1] & ~syncedBit)
            guard idx < phases.count else { return nil }
            let synced = b[1] & syncedBit != 0
            let angle = Double(Float(bitPattern: b.u32(at: 2)))
            let omega = Double(Float(bitPattern: b.u32(at: 6)))
            let time = Double(bitPattern: b.u64(at: 10))
            return .sample(ClubSample(angle: angle, omega: omega, phase: phases[idx], time: synced ? time : nil))
        case pingType:
            guard b.count >= 9 else { return nil }
            return .ping(t0: Double(bitPattern: b.u64(at: 1)))
        case pongType:
            guard b.count >= 17 else { return nil }
            return .pong(t0: Double(bitPattern: b.u64(at: 1)), t1: Double(bitPattern: b.u64(at: 9)))
        case impactType:
            guard b.count >= 19 else { return nil }
            let synced = b[1] & syncedBit != 0
            let conf = Double(b[1] & ~syncedBit) / 100
            let time = Double(bitPattern: b.u64(at: 2))
            let wrist = Double(Float(bitPattern: b.u32(at: 10)))
            let back = Double(UInt16(b[14]) | UInt16(b[15]) << 8) / 1000
            let down = Double(UInt16(b[16]) | UInt16(b[17]) << 8) / 1000
            let faceRaw = Int8(bitPattern: b[18])
            return .impact(QuickImpact(time: synced ? time : nil, wristSpeed: wrist, backswing: back, downswing: down,
                                       faceAngle: faceRaw == noFace ? nil : Double(faceRaw), confidence: conf))
        default:
            return nil
        }
    }
}

extension Data {
    mutating func appendLE(_ v: Float) {
        var x = v.bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ v: UInt16) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ v: Double) {
        var x = v.bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
}

extension Array where Element == UInt8 {
    func u32(at i: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[i + $1]) << (8 * UInt32($1)) }
    }

    func u64(at i: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[i + $1]) << (8 * UInt64($1)) }
    }
}
