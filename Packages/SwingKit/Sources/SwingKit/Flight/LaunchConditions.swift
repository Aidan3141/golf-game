import Foundation

// what the ball does right off the club. angles in degrees
public struct LaunchConditions: Sendable, Hashable {
    public var ballSpeed: Double  // m/s
    public var launchAngle: Double  // up from ground
    public var startDirection: Double  // + = right of target
    public var spinAxisTilt: Double  // + = curves right

    public init(ballSpeed: Double, launchAngle: Double, startDirection: Double, spinAxisTilt: Double) {
        self.ballSpeed = ballSpeed
        self.launchAngle = launchAngle
        self.startDirection = startDirection
        self.spinAxisTilt = spinAxisTilt
    }
}

extension LaunchConditions {
    // game-y mapping, forgiving on purpose. same swing always gives same launch (seeded by swing id)
    public init(swing: SwingResult, tuning t: FlightTuning = .standard) {
        var rng = SeededRandom(uuid: swing.id)
        let smooth = min(max(swing.smoothnessScore, 0), 1)
        let rough = 1 - smooth
        // rh slice goes right, lh slice goes left
        let hand: Double = swing.handedness == .right ? 1 : -1
        let path = min(max(swing.pathBias, -1), 1)

        var speed = swing.peakWristAngularVelocity * t.speedPerWristRadPerSec
        speed *= 1 - t.smoothnessSpeedPenalty * rough
        speed = min(max(speed, t.minBallSpeed), t.maxBallSpeed)

        let tempoError = min(abs(swing.tempoRatio - t.targetTempo) / t.targetTempo, 1)
        let curveBoost = 1 + t.tempoCurveGain * tempoError

        let launch = t.launchAngleDegrees + rng.next(in: -1...1) * t.maxRandomLaunchAngleDegrees * rough
        let start = path * hand * t.startLineDegreesPerPathBias
            + rng.next(in: -1...1) * t.maxRandomStartDegrees * rough
        // out-to-in (neg path) -> curves right for rh
        let tilt = -path * hand * t.curveDegreesPerPathBias * curveBoost

        self.init(
            ballSpeed: speed,
            launchAngle: launch,
            startDirection: start,
            spinAxisTilt: min(max(tilt, -t.maxSpinAxisTiltDegrees), t.maxSpinAxisTiltDegrees)
        )
    }
}
