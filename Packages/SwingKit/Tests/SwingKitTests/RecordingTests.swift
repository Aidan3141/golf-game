import Foundation
import Testing
@testable import SwingKit

@Suite struct RingBufferTests {
    @Test func keepsNewestInOrder() {
        var b = RingBuffer<Int>(capacity: 3)
        b.append(contentsOf: 1...5)
        #expect(b.elements == [3, 4, 5])
        #expect(b.count == 3)
    }

    @Test func partialFill() {
        var b = RingBuffer<Int>(capacity: 4)
        b.append(1)
        b.append(2)
        #expect(b.elements == [1, 2])
    }

    @Test func clear() {
        var b = RingBuffer<Int>(capacity: 2)
        b.append(contentsOf: [1, 2, 3])
        b.removeAll()
        #expect(b.elements.isEmpty)
        b.append(9)
        #expect(b.elements == [9])
    }
}

@Suite struct SwingRecordingTests {
    static func make() -> SwingRecording {
        let accel = (0..<800).map { i in AccelSample(t: Double(i) / 800, x: 0, y: -1, z: Double(i) / 800) }
        let motion = (0..<200).map { i in
            MotionFrame(t: Double(i) / 200, rotX: 1, rotY: 2, rotZ: 2, userX: 0, userY: 0, userZ: 0,
                        gravX: 0, gravY: -1, gravZ: 0, qw: 1, qx: 0, qy: 0, qz: 0)
        }
        return SwingRecording(startedAt: Date(timeIntervalSince1970: 1_800_000_000), duration: 1,
                              handedness: .right, wrist: "left", source: "batched",
                              accelHz: 800, motionHz: 200, accel: accel, motion: motion)
    }

    @Test func roundTrip() throws {
        let r = Self.make()
        #expect(try SwingRecording.decode(r.encoded()) == r)
    }

    @Test func measuredRates() {
        let r = Self.make()
        #expect(abs(r.measuredAccelHz - 800) < 1)
        #expect(abs(r.measuredMotionHz - 200) < 1)
        #expect(r.motion[0].rotationMagnitude == 3)
    }

    @Test func csvHasHeaderAndRows() {
        let r = Self.make()
        let lines = r.accelCSV().split(separator: "\n")
        #expect(lines.first == "t,ax,ay,az")
        #expect(lines.count == 801)
        #expect(r.motionCSV().split(separator: "\n").count == 201)
    }

    @Test func fileNameLooksRight() {
        #expect(Self.make().fileName.hasPrefix("swing-"))
        #expect(Self.make().fileName.hasSuffix(".json"))
    }
}
