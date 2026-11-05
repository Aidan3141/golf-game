import Foundation

// splitmix64. tiny + deterministic so tests are stable
struct SeededRandom: Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    // uuid bytes -> seed, stable across launches (unlike hashValue)
    init(uuid: UUID) {
        let b = uuid.uuid
        let hi = [b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let lo = [b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        self.init(seed: hi ^ lo)
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        let unit = Double(nextUInt64() >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
