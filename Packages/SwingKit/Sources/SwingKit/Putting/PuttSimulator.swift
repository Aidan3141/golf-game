import Foundation
import simd

// what kind of swing were expecting. avp tells the watch (thru the phone) which one
public enum SwingMode: String, Codable, Sendable, CaseIterable {
    case full
    case putt
}

public struct PuttTuning: Sendable, Hashable {
    public var speedPerWristRadPerSec = 0.6  // ball m/s per rad/s. ~3 rad/s stroke rolls ~3m
    public var maxSpeed = 4.0  // m/s
    public var rollDeceleration = 0.55  // m/s^2, about stimp 10
    public var slopeFactor = 5.0 / 7.0  // rolling ball feels 5/7 of the slope pull
    public var gravity = 9.81
    public var aimDegreesPerFaceDegree = 0.9  // putts go where the face points
    public var cupRadius = 0.054  // m, regulation 4.25in
    public var ballRadius = 0.02135
    public var maxCaptureSpeed = 1.3  // m/s, faster than this over the cup = lip out
    public var timeStep = 1.0 / 240.0
    public var outputInterval = 1.0 / 60.0
    public var maxTime = 15.0

    public init() {}
    public static let standard = PuttTuning()
}

// green coords: x right of target line, z toward the hole, meters. ball starts at 0,0
public struct PuttSetup: Sendable, Hashable {
    public var hole: SIMD2<Double>  // (x, z)
    public var slope: SIMD2<Double>  // downhill direction * grade (0.02 = 2%), (x, z)

    public init(hole: SIMD2<Double>, slope: SIMD2<Double> = .zero) {
        self.hole = hole
        self.slope = slope
    }

    public var distance: Double { simd_length(hole) }
}

public struct PuttResult: Sendable, Hashable {
    public var points: [FlightPoint]  // y is 0 on the green, goes negative when it drops in
    public var holed: Bool
    public var lippedOut: Bool
    public var rest: SIMD2<Double>
    public var leftToHole: Double  // m from rest to cup center, 0 if holed
    public var duration: Double
}

public enum PuttSimulator {
    // stroke -> start speed + direction (deg, + = right)
    public static func launch(_ swing: SwingResult, faceToAim: Double, tuning t: PuttTuning = .standard) -> (speed: Double, aim: Double) {
        var speed = swing.peakWristAngularVelocity * t.speedPerWristRadPerSec
        // jerky strokes come off the face a bit hot or dead, keep it small
        speed *= 1 - 0.1 * (1 - min(max(swing.smoothnessScore, 0), 1))
        return (min(max(speed, 0.05), t.maxSpeed), faceToAim * t.aimDegreesPerFaceDegree)
    }

    public static func simulate(speed: Double, aimDegrees: Double, setup: PuttSetup, tuning t: PuttTuning = .standard) -> PuttResult {
        let a = aimDegrees * .pi / 180
        var p = SIMD2<Double>(0, 0)
        var v = SIMD2<Double>(sin(a), cos(a)) * speed
        let slopeAccel = setup.slope * t.gravity * t.slopeFactor
        var time = 0.0
        var nextOut = 0.0
        var points: [FlightPoint] = []
        var lippedOut = false

        func record(_ y: Double = 0) {
            points.append(FlightPoint(time: time, position: SIMD3(p.x, y, p.y)))
        }
        record()

        while time < t.maxTime {
            time += t.timeStep
            let s = simd_length(v)
            // friction against motion + slope pull
            var accel = slopeAccel
            if s > 1e-6 { accel -= v / s * t.rollDeceleration }
            let newV = v + accel * t.timeStep
            // friction cant reverse u, if its going to flip + slope is weak, stop
            if s > 1e-6, simd_dot(newV, v) < 0, simd_length(slopeAccel) < t.rollDeceleration {
                v = .zero
            } else {
                v = newV
            }
            p += v * t.timeStep

            // over the cup?
            if simd_distance(p, setup.hole) < t.cupRadius - t.ballRadius * 0.3 {
                if simd_length(v) <= t.maxCaptureSpeed {
                    p = setup.hole
                    record()
                    // little drop animation
                    for i in 1...6 {
                        time += t.outputInterval
                        record(-0.012 * Double(i))
                    }
                    return PuttResult(points: points, holed: true, lippedOut: false, rest: setup.hole,
                                      leftToHole: 0, duration: time)
                }
                lippedOut = true
            }

            if time >= nextOut {
                record()
                nextOut += t.outputInterval
            }
            if simd_length(v) < 0.005 && simd_length(slopeAccel) < t.rollDeceleration {
                break
            }
        }
        record()
        return PuttResult(points: points, holed: false, lippedOut: lippedOut, rest: p,
                          leftToHole: simd_distance(p, setup.hole), duration: time)
    }

    // speed u need to just roll it to a spot (flat). handy for tests + "ideal" hints
    public static func idealSpeed(for distance: Double, tuning t: PuttTuning = .standard) -> Double {
        (2 * t.rollDeceleration * distance).squareRoot()
    }
}

extension SwingDetectorConfig {
    // putts are tiny. GUESSES til we have recorded putts to tune on
    public static let putting: SwingDetectorConfig = {
        var c = SwingDetectorConfig()
        c.stillThreshold = 0.25
        c.takeawayThreshold = 0.2
        c.impactMinPeak = 1.2
        c.minBackswingHump = 0.35
        c.maxTopRatio = 0.5
        c.topAbsolute = 0.4
        c.downswing = 0.12...1.2
        c.backswing = 0.25...2.0
        c.topSearch = 0.1...1.2
        c.humpSearch = 0.1...2.0
        c.refractory = 1.5
        return c
    }()
}

extension Coach {
    public static let puttTempoGood = 1.6...2.4  // good putters are ~2:1

    public static func puttTip(for swing: SwingResult, result: PuttResult) -> CoachingTip {
        let tempo = swing.tempoRatio
        let ft = result.leftToHole * 3.28084
        if result.holed {
            return CoachingTip(kind: .great, title: "In the hole!", detail: String(format: "Stroke tempo %.1f:1. Nice roll.", tempo))
        }
        if result.lippedOut {
            return CoachingTip(kind: .solid, title: "Lipped out", detail: "Right line, just too firm. Same stroke, a touch softer.")
        }
        if tempo < puttTempoGood.lowerBound {
            return CoachingTip(kind: .rushedTempo, title: "Hit at it",
                               detail: String(format: "Tempo %.1f:1. Let the putter swing back and through like a pendulum, ~2:1.", tempo))
        }
        if tempo > puttTempoGood.upperBound {
            return CoachingTip(kind: .slowTempo, title: "Decelerated",
                               detail: String(format: "Tempo %.1f:1. Shorter backstroke, then accelerate thru the ball.", tempo))
        }
        return CoachingTip(kind: .solid, title: String(format: "%.1f ft away", ft),
                           detail: "Good tempo. Match the length of ur backstroke to the distance.")
    }
}
