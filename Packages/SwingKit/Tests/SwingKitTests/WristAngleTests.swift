import Foundation
import Testing
@testable import SwingKit

@Suite struct WristAngleTests {
    // 4932 starts w/ a proper still address so angles are meaningful
    func addressedSwing() throws -> SwingRecording {
        try #require(Fixtures.all.first { $0.id.uuidString.hasPrefix("4932") })
    }

    @Test func angleShapeMatchesASwing() throws {
        let rec = try addressedSwing()
        var d = SwingDetector()
        var angles: [(Double, Double)] = []
        var impactT: Double?
        for m in rec.motion {
            for e in d.add(motion: [m]) {
                if case .impact(_, let tl) = e { impactT = tl.impact }
            }
            if let a = d.currentAngle { angles.append((m.t, a * 180 / .pi)) }
        }
        let imp = try #require(impactT)
        let top = angles.filter { $0.0 < imp }.map(\.1).max() ?? 0
        let atImpact = angles.min { abs($0.0 - imp) < abs($1.0 - imp) }?.1 ?? 999
        let finish = angles.filter { $0.0 > imp }.map(\.1).min() ?? 0
        #expect(top > 90, "top \(top)")
        #expect(abs(atImpact) < 25, "impact \(atImpact)")
        #expect(finish < -40, "finish \(finish)")
    }

    @Test func faceAngleComesOutForAddressedSwing() throws {
        let rec = try addressedSwing()
        var d = SwingDetector()
        var face: Double?
        for e in d.add(motion: rec.motion) {
            if case .impact(let r, _) = e { face = r.faceAngle }
        }
        let f = try #require(face)
        #expect(abs(f) < 45, "face \(f)")
    }

    @Test func noAddressNoAngle() {
        var t = SwingAngleTracker()
        let f = MotionFrame(t: 0, rotX: 0, rotY: 0, rotZ: 0, userX: 0, userY: 0, userZ: 0,
                            gravX: 0, gravY: -1, gravZ: 0, qw: 1, qx: 0, qy: 0, qz: 0)
        #expect(t.angle(f) == nil)
        #expect(t.faceAngle(f) == nil)
    }

    @Test func pureRollIsAllFace() {
        // twist 20 deg about the forearm (x) w/ a swing axis of y -> face = 20
        var t = SwingAngleTracker()
        let id = MotionFrame(t: 0, rotX: 0, rotY: 0, rotZ: 0, userX: 0, userY: 0, userZ: 0,
                             gravX: 0, gravY: -1, gravZ: 0, qw: 1, qx: 0, qy: 0, qz: 0)
        t.setReference(id)
        // lock the axis to y w/ a big swing first
        let h = 0.6 / 2
        _ = t.angle(MotionFrame(t: 0.1, rotX: 0, rotY: 0, rotZ: 0, userX: 0, userY: 0, userZ: 0,
                                gravX: 0, gravY: -1, gravZ: 0, qw: cos(h), qx: 0, qy: sin(h), qz: 0))
        let r = 20.0 * .pi / 180 / 2
        let rolled = MotionFrame(t: 0.2, rotX: 0, rotY: 0, rotZ: 0, userX: 0, userY: 0, userZ: 0,
                                 gravX: 0, gravY: -1, gravZ: 0, qw: cos(r), qx: sin(r), qy: 0, qz: 0)
        #expect(abs((t.faceAngle(rolled) ?? 0) - 20) < 0.01)
    }
}
