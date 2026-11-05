import Foundation
import SwingKit

// slider values for fake swings
struct TestSwingSettings: Equatable {
    var handedness = Handedness.right
    var backswing = 0.75  // s
    var downswing = 0.25  // s
    var wristSpeed = 22.0  // rad/s
    var smoothness = 0.8
    var pathBias = 0.0

    var tempoRatio: Double { downswing > 0 ? backswing / downswing : 0 }

    // fresh id each time so dispersion rng changes shot to shot
    func makeSwing() -> SwingResult {
        SwingResult(
            handedness: handedness,
            backswingDuration: backswing,
            downswingDuration: downswing,
            peakWristAngularVelocity: wristSpeed,
            peakAcceleration: wristSpeed * 0.4,
            smoothnessScore: smoothness,
            pathBias: pathBias,
            confidence: 1
        )
    }

    static func random() -> TestSwingSettings {
        var s = TestSwingSettings()
        s.backswing = .random(in: 0.5...1.1)
        s.downswing = .random(in: 0.2...0.4)
        s.wristSpeed = .random(in: 15...30)
        s.smoothness = .random(in: 0.3...1)
        s.pathBias = .random(in: -0.8...0.8)
        return s
    }
}
