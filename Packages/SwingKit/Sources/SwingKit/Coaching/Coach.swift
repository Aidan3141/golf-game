import Foundation

// one plain english tip per shot. picks the biggest problem, beginner friendly, never mean
public struct CoachingTip: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case rushedTempo, slowTempo, jerky, slice, hook, lowSpeed, great, solid
    }

    public var kind: Kind
    public var title: String
    public var detail: String
}

public enum Coach {
    // tweakable cutoffs
    public static let tempoGood = 2.6...3.4
    public static let smoothGood = 0.6
    public static let curveYards = 12.0  // offline more than this = worth talking about
    public static let lowSpeed = 13.0  // rad/s

    public static func tip(for swing: SwingResult, flight: FlightResult) -> CoachingTip {
        let tempo = swing.tempoRatio
        let off = Units.yards(flight.offline)
        let rightHanded = swing.handedness == .right
        // slice = curves away from ur lead side
        let isSlice = rightHanded ? off > curveYards : off < -curveYards
        let isHook = rightHanded ? off < -curveYards : off > curveYards

        if tempo < tempoGood.lowerBound {
            return CoachingTip(
                kind: .rushedTempo,
                title: "Rushed downswing",
                detail: String(format: "Tempo %.1f:1. Count \"1-2-3\" on the way back and \"1\" on the way down.", tempo)
            )
        }
        if tempo > tempoGood.upperBound {
            return CoachingTip(
                kind: .slowTempo,
                title: "Lazy downswing",
                detail: String(format: "Tempo %.1f:1. Keep the same backswing but let it go a bit quicker through the ball.", tempo)
            )
        }
        if swing.smoothnessScore < smoothGood {
            return CoachingTip(
                kind: .jerky,
                title: "Jerky takeaway",
                detail: "Start the club back low and slow, like one smooth push. No snatching."
            )
        }
        if isSlice {
            return CoachingTip(
                kind: .slice,
                title: String(format: "Slice, %.0f yd off line", abs(off)),
                detail: "Clubface was open at impact. Feel your lead hand knuckles turn down toward the ground through the ball."
            )
        }
        if isHook {
            return CoachingTip(
                kind: .hook,
                title: String(format: "Hook, %.0f yd off line", abs(off)),
                detail: "Clubface closed too early. Hold the clubface square a little longer after impact."
            )
        }
        if swing.peakWristAngularVelocity < lowSpeed {
            return CoachingTip(
                kind: .lowSpeed,
                title: "Nice and easy",
                detail: "Good rhythm. When it feels comfy, make a bigger turn for more distance."
            )
        }
        if abs(tempo - 3) < 0.2 && swing.smoothnessScore > 0.75 {
            return CoachingTip(kind: .great, title: "Pure!", detail: "That's the tempo. Do exactly that again.")
        }
        return CoachingTip(kind: .solid, title: "Solid swing", detail: String(format: "Tempo %.1f:1, right in the zone. Keep it up.", tempo))
    }
}

// rolling stats for a practice session
public struct SessionStats: Sendable, Hashable {
    public var shots: Int
    public var averageTempo: Double
    public var tempoSpread: Double  // std dev, lower = more consistent
    public var averageCarry: Double  // m
    public var bestCarry: Double  // m
    public var averageSmoothness: Double

    public init(swings: [SwingResult], flights: [FlightResult]) {
        shots = swings.count
        let tempos = swings.map(\.tempoRatio)
        averageTempo = Self.mean(tempos)
        tempoSpread = Self.stdDev(tempos)
        averageCarry = Self.mean(flights.map(\.carry))
        bestCarry = flights.map(\.carry).max() ?? 0
        averageSmoothness = Self.mean(swings.map(\.smoothnessScore))
    }

    // words for the spread, beginners dont care about std dev
    public var consistencyLabel: String {
        switch tempoSpread {
        case ..<0.2: "very consistent"
        case ..<0.4: "pretty consistent"
        case ..<0.7: "a bit all over"
        default: "all over the place"
        }
    }

    static func mean(_ x: [Double]) -> Double {
        x.isEmpty ? 0 : x.reduce(0, +) / Double(x.count)
    }

    static func stdDev(_ x: [Double]) -> Double {
        guard x.count > 1 else { return 0 }
        let m = mean(x)
        return (x.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(x.count - 1)).squareRoot()
    }
}
