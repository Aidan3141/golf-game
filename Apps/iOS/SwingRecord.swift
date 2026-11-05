import Foundation
import SwiftData
import SwingKit

// one real swing in history. flat fields so swiftdata doesnt choke on nested codables
@Model
final class SwingRecord {
    @Attribute(.unique) var id: UUID
    var date: Date
    var handedness: String
    var backswing: Double
    var downswing: Double
    var peakWristSpeed: Double
    var peakAccel: Double
    var smoothness: Double
    var faceAngle: Double?
    var confidence: Double
    var carryYards: Double
    var totalYards: Double
    var offlineYards: Double
    var tipTitle: String

    var tempo: Double { downswing > 0 ? backswing / downswing : 0 }

    init(_ s: SwingResult) {
        id = s.id
        date = s.timestamp
        handedness = s.handedness.rawValue
        backswing = s.backswingDuration
        downswing = s.downswingDuration
        peakWristSpeed = s.peakWristAngularVelocity
        peakAccel = s.peakAcceleration
        smoothness = s.smoothnessScore
        faceAngle = s.faceAngle
        confidence = s.confidence
        // phone doesnt know the avps curve calibration, so this is a straight shot estimate
        let f = FlightSimulator.simulate(swing: s)
        carryYards = Units.yards(f.carry)
        totalYards = Units.yards(f.total)
        offlineYards = Units.yards(f.offline)
        tipTitle = Coach.tip(for: s, flight: f).title
    }
}
