import Foundation
import Testing
@testable import SwingKit

@Suite struct ClockSyncTests {
    @Test func symmetricDelayGivesExactOffset() {
        var c = ClockOffsetEstimator()
        // their clock is 100s ahead, 20ms each way
        c.add(sent: 10.0, remote: 110.02, received: 10.04)
        #expect(abs(c.offset! - 100) < 1e-9)
        #expect(abs(c.bestRTT! - 0.04) < 1e-9)
        #expect(abs(c.toRemote(11)! - 111) < 1e-9)
    }

    @Test func picksTheFastestRoundTrip() {
        var c = ClockOffsetEstimator()
        c.add(sent: 0, remote: 100.30, received: 0.4)  // slow + lopsided, offset 99.9
        c.add(sent: 1, remote: 101.005, received: 1.01)  // fast, offset 100.0
        c.add(sent: 2, remote: 102.2, received: 2.25)  // medium
        #expect(abs(c.offset! - 100) < 1e-9)
        #expect(abs(c.uncertainty! - 0.005) < 1e-9)
    }

    @Test func asymmetricErrorIsBoundedByHalfRTT() {
        var c = ClockOffsetEstimator()
        // true offset 50, out leg 5ms, back leg 25ms
        c.add(sent: 0, remote: 50.005, received: 0.03)
        #expect(abs(c.offset! - 50) <= c.uncertainty! + 1e-9)
    }

    @Test func junkIgnoredAndWindowSlides() {
        var c = ClockOffsetEstimator(window: 2)
        #expect(c.offset == nil)
        c.add(sent: 5, remote: 1, received: 4)  // negative rtt
        c.add(sent: 0, remote: 1, received: 3)  // 3s rtt
        #expect(c.offset == nil)
        c.add(sent: 0, remote: 10.001, received: 0.002)  // best, offset 10
        c.add(sent: 1, remote: 11.3, received: 1.2)  // offset 10.2
        c.add(sent: 2, remote: 12.3, received: 2.2)  // offset 10.2, pushes the best one out
        #expect(c.samples.count == 2)
        #expect(abs(c.offset! - 10.2) < 1e-9)
    }
}

@Suite struct ClubSampleTests {
    let s = ClubSample(angle: 1.0, omega: 10, phase: .downswing, time: 5.0)

    @Test func noTimeNoPrediction() {
        let u = ClubSample(angle: 1, omega: 10, phase: .downswing, time: nil)
        #expect(u.predictedAngle(at: 99) == 1)
    }

    @Test func predictsForward() {
        #expect(abs(s.predictedAngle(at: 5.05) - 1.5) < 1e-9)
    }

    @Test func pastTimeHolds() {
        #expect(s.predictedAngle(at: 4.0) == 1.0)
    }

    @Test func capsHorizonAndDelta() {
        #expect(abs(s.predictedAngle(at: 9, maxHorizon: 0.1, maxDelta: 5) - 2.0) < 1e-9)
        #expect(abs(s.predictedAngle(at: 5.2, maxHorizon: 1, maxDelta: 0.5) - 1.5) < 1e-9)
    }

    @Test func shiftMovesClockOrDropsIt() {
        #expect(s.shifted(by: 10).time == 15)
        #expect(s.shifted(by: nil).time == nil)
    }

    @Test func rateTrackerOnARamp() {
        var r = AngleRateTracker(window: 0.03)
        var w = 0.0
        for i in 0..<20 {
            let t = Double(i) * 0.01
            w = r.add(t: t, angle: 3 * t)  // 3 rad/s
        }
        #expect(abs(w - 3) < 1e-9)
        r.reset()
        #expect(r.add(t: 1, angle: 0) == 0)
    }
}

@Suite struct OneEuroTests {
    @Test func firstValuePassesThrough() {
        var f = OneEuroFilter()
        #expect(f.filter(5, t: 0) == 5)
    }

    @Test func constantStaysConstant() {
        var f = OneEuroFilter()
        var y = 0.0
        for i in 0..<50 { y = f.filter(2, t: Double(i) / 90) }
        #expect(abs(y - 2) < 1e-12)
    }

    @Test func calmsJitterWhenStill() {
        var f = OneEuroFilter(minCutoff: 1, beta: 0)
        var rng = SeededRandom(seed: 3)
        var rawVar = 0.0, outVar = 0.0
        for i in 0..<400 {
            let noise = rng.next(in: -0.01...0.01)
            let y = f.filter(noise, t: Double(i) / 90)
            if i > 50 { rawVar += noise * noise; outVar += y * y }
        }
        #expect(outVar < rawVar * 0.2)
    }

    @Test func betaKeepsUpWithFastMotion() {
        // ramp at 5 m/s, sampled at 90hz
        var slow = OneEuroFilter(minCutoff: 1, beta: 0)
        var fast = OneEuroFilter(minCutoff: 1, beta: 2)
        var lagSlow = 0.0, lagFast = 0.0
        for i in 0..<90 {
            let t = Double(i) / 90
            lagSlow = 5 * t - slow.filter(5 * t, t: t)
            lagFast = 5 * t - fast.filter(5 * t, t: t)
        }
        #expect(lagFast < lagSlow * 0.2)
        #expect(lagFast < 0.05)
    }

    @Test func vectorVersion() {
        var f = OneEuroFilter3()
        #expect(f.filter([1, 2, 3], t: 0) == SIMD3(1, 2, 3))
    }
}

@Suite struct ClubPacketTests {
    @Test func sampleRoundTrip() throws {
        let s = ClubSample(angle: 1.25, omega: -14.5, phase: .downswing, time: 12345.678)
        let d = ClubPacket.sample(s).encoded()
        #expect(d.count <= 20)
        guard case .sample(let back) = try #require(ClubPacket.decode(d)) else { Issue.record("wrong type"); return }
        #expect(abs(back.angle - 1.25) < 1e-6)
        #expect(abs(back.omega + 14.5) < 1e-6)
        #expect(back.phase == .downswing)
        #expect(back.time == 12345.678)
    }

    @Test func unsyncedSampleHasNoTime() throws {
        let d = ClubPacket.sample(ClubSample(angle: 0, omega: 0, phase: .address, time: nil)).encoded()
        guard case .sample(let back) = try #require(ClubPacket.decode(d)) else { Issue.record("wrong type"); return }
        #expect(back.time == nil)
        #expect(back.phase == .address)
    }

    @Test func pingPongRoundTrip() {
        #expect(ClubPacket.decode(ClubPacket.ping(t0: 1.5).encoded()) == .ping(t0: 1.5))
        #expect(ClubPacket.decode(ClubPacket.pong(t0: 1.5, t1: 99.25).encoded()) == .pong(t0: 1.5, t1: 99.25))
        #expect(ClubPacket.pong(t0: 0, t1: 0).encoded().count <= 20)
    }

    @Test func junkIsNil() {
        #expect(ClubPacket.decode(Data()) == nil)
        #expect(ClubPacket.decode(Data([1, 2, 3])) == nil)
        #expect(ClubPacket.decode(Data([9] + Array(repeating: 0, count: 20))) == nil)
        #expect(ClubPacket.decode(Data([1, 0x7F] + Array(repeating: 0, count: 16))) == nil)
    }
}

@Suite struct EnvelopeV2Tests {
    @Test func newPayloadsRoundTrip() throws {
        let swing = SwingResult(id: UUID(), timestamp: Date(timeIntervalSince1970: 7), handedness: .right,
                                backswingDuration: 0.9, downswingDuration: 0.3, peakWristAngularVelocity: 19,
                                peakAcceleration: 11, smoothnessScore: 0.7, pathBias: 0, confidence: 0.9)
        for p: MessagePayload in [
            .clubSample(ClubSample(angle: 1, omega: 2, phase: .backswing, time: 3)),
            .swingAt(swing, impactTime: 42.5),
            .swingAt(swing, impactTime: nil),
            .clockPing(t0: 1),
            .clockPong(t0: 1, t1: 2),
        ] {
            let env = MessageEnvelope(payload: p, sentAt: Date(timeIntervalSince1970: 0))
            #expect(try MessageEnvelope.decode(env.encoded()) == env)
        }
        #expect(MessageEnvelope.currentVersion == 2)
    }
}
