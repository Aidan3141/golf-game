import Foundation
import Testing
@testable import SwingKit

@Suite struct SwingResultTests {
    @Test func tempoRatio() {
        let r = SwingResult.sample
        #expect(abs(r.tempoRatio - 0.75 / 0.27) < 1e-9)
    }

    @Test func tempoRatioZeroDownswing() {
        let r = SwingResult(handedness: .left, backswingDuration: 1, downswingDuration: 0,
                            peakWristAngularVelocity: 0, peakAcceleration: 0,
                            smoothnessScore: 0, pathBias: 0, confidence: 0)
        #expect(r.tempoRatio == 0)
    }
}

@Suite struct MessageEnvelopeTests {
    @Test func swingRoundTrip() throws {
        // whole secs so iso8601 doesnt drop fractional part
        let r = SwingResult(id: UUID(), timestamp: Date(timeIntervalSince1970: 1_800_000_000),
                            handedness: .right, backswingDuration: 0.8, downswingDuration: 0.3,
                            peakWristAngularVelocity: 20, peakAcceleration: 8,
                            smoothnessScore: 0.6, pathBias: 0.1, confidence: 0.95)
        let env = MessageEnvelope(payload: .swing(r), sentAt: Date(timeIntervalSince1970: 1_800_000_001))
        let back = try MessageEnvelope.decode(env.encoded())
        #expect(back == env)
        #expect(back.version == MessageEnvelope.currentVersion)
    }

    @Test func pingRoundTrip() throws {
        let env = MessageEnvelope(payload: .ping, sentAt: Date(timeIntervalSince1970: 0))
        #expect(try MessageEnvelope.decode(env.encoded()) == env)
    }
}
