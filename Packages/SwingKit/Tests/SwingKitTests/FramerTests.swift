import Foundation
import Testing
@testable import SwingKit

@Suite struct FramerTests {
    // whole secs, iso8601 drops fractions
    let a = MessageEnvelope(payload: .swing(SwingResult(
        id: UUID(), timestamp: Date(timeIntervalSince1970: 50), handedness: .right,
        backswingDuration: 0.9, downswingDuration: 0.3, peakWristAngularVelocity: 19,
        peakAcceleration: 11, smoothnessScore: 0.7, pathBias: 0, confidence: 0.9
    )), sentAt: Date(timeIntervalSince1970: 100))
    let b = MessageEnvelope(payload: .ping, sentAt: Date(timeIntervalSince1970: 200))
    let c = MessageEnvelope(payload: .hello(device: "iPhone"), sentAt: Date(timeIntervalSince1970: 300))

    @Test func roundTripSeveralInOneChunk() throws {
        var d = FrameDecoder()
        let bytes = try MessageFramer.frame(a) + MessageFramer.frame(b) + MessageFramer.frame(c)
        let out = d.append(bytes)
        #expect(out.count == 3)
        #expect(out[2].payload == .hello(device: "iPhone"))
    }

    @Test func handlesByteAtATime() throws {
        var d = FrameDecoder()
        let bytes = try MessageFramer.frame(a) + MessageFramer.frame(b)
        var out: [MessageEnvelope] = []
        for byte in bytes {
            out += d.append(Data([byte]))
        }
        #expect(out.count == 2)
        #expect(out[0].payload == a.payload)
    }

    @Test func garbageDoesntCrash() {
        var d = FrameDecoder()
        let out = d.append(Data([0xFF, 0xFF, 0xFF, 0xFF, 1, 2, 3]))
        #expect(out.isEmpty)
        #expect(d.droppedFrames == 1)
    }

    @Test func badJsonSkipped() throws {
        var d = FrameDecoder()
        var junk = Data([0, 0, 0, 3])
        junk.append(contentsOf: [1, 2, 3])
        let out = d.append(junk + (try MessageFramer.frame(b)))
        #expect(out.count == 1)
        #expect(d.droppedFrames == 1)
    }
}
