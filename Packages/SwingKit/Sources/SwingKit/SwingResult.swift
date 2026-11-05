import Foundation

// small summary the watch sends after a swing. raw samples go separately
public struct SwingResult: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let handedness: Handedness
    public let backswingDuration: TimeInterval  // takeaway -> top
    public let downswingDuration: TimeInterval  // top -> impact
    public let peakWristAngularVelocity: Double  // rad/s near impact
    public let peakAcceleration: Double  // g
    public let smoothnessScore: Double  // 0-1
    public let pathBias: Double  // -1 out-to-in (slice) ... +1 in-to-out (hook)
    public let confidence: Double  // 0-1, how sure it was a real swing
    public var faceAngle: Double?  // deg, forearm roll at impact vs address. sign calibrated on avp

    // target ~3.0. 0 if downswing is 0 so no div by zero
    public var tempoRatio: Double {
        downswingDuration > 0 ? backswingDuration / downswingDuration : 0
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        handedness: Handedness,
        backswingDuration: TimeInterval,
        downswingDuration: TimeInterval,
        peakWristAngularVelocity: Double,
        peakAcceleration: Double,
        smoothnessScore: Double,
        pathBias: Double,
        confidence: Double,
        faceAngle: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.handedness = handedness
        self.backswingDuration = backswingDuration
        self.downswingDuration = downswingDuration
        self.peakWristAngularVelocity = peakWristAngularVelocity
        self.peakAcceleration = peakAcceleration
        self.smoothnessScore = smoothnessScore
        self.pathBias = pathBias
        self.confidence = confidence
        self.faceAngle = faceAngle
    }
}

extension SwingResult {
    // decent beginner swing, handy for previews + fake shots
    public static let sample = SwingResult(
        handedness: .right,
        backswingDuration: 0.75,
        downswingDuration: 0.27,
        peakWristAngularVelocity: 19,  // typical real swing (16-21 on nov 5)
        peakAcceleration: 9,
        smoothnessScore: 0.7,
        pathBias: -0.2,
        confidence: 0.9
    )
}

extension SwingResult {
    // same swing, new id + time. for test sends
    public func fresh() -> SwingResult {
        SwingResult(
            handedness: handedness,
            backswingDuration: backswingDuration,
            downswingDuration: downswingDuration,
            peakWristAngularVelocity: peakWristAngularVelocity,
            peakAcceleration: peakAcceleration,
            smoothnessScore: smoothnessScore,
            pathBias: pathBias,
            confidence: confidence,
            faceAngle: faceAngle
        )
    }

    // copy w/ a new path, avp maps faceAngle -> pathBias w/ its own calibration
    public func with(pathBias: Double) -> SwingResult {
        SwingResult(
            id: id, timestamp: timestamp, handedness: handedness,
            backswingDuration: backswingDuration, downswingDuration: downswingDuration,
            peakWristAngularVelocity: peakWristAngularVelocity, peakAcceleration: peakAcceleration,
            smoothnessScore: smoothnessScore, pathBias: pathBias, confidence: confidence, faceAngle: faceAngle
        )
    }
}
