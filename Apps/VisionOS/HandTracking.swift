import ARKit
import Foundation
import QuartzCore
import simd

// one arkit hand tracking session for the whole app. the club + address check both read from it
@MainActor
final class HandTracking {
    struct Pose {
        var wrist: SIMD3<Float>
        var palm: SIMD3<Float>  // middle finger metacarpal, ~center of the grip
        var rotation: simd_quatf  // world from hand
    }

    enum State: Equatable {
        case off, starting, running, unsupported, denied
    }

    private(set) var state = State.off
    private var session: ARKitSession?
    private var provider: HandTrackingProvider?

    // how far ahead to predict, hides tracking + render latency
    var lookahead = 0.025

    func start() {
        guard state == .off || state == .denied else { return }
        guard HandTrackingProvider.isSupported else {
            state = .unsupported
            return
        }
        let s = ARKitSession()
        let p = HandTrackingProvider()
        session = s
        provider = p
        state = .starting
        Task {
            do {
                try await s.run([p])
                if self.provider === p { self.state = .running }
            } catch {
                self.state = .denied
            }
        }
    }

    func stop() {
        session?.stop()
        session = nil
        provider = nil
        state = .off
    }

    // predicted poses for right about when this frame shows up
    func predicted() -> (left: Pose?, right: Pose?) {
        guard state == .running, let provider else { return (nil, nil) }
        let pair = provider.handAnchors(at: CACurrentMediaTime() + lookahead)
        return (Self.pose(pair.leftHand), Self.pose(pair.rightHand))
    }

    private static func pose(_ a: HandAnchor?) -> Pose? {
        guard let a, a.isTracked, let skel = a.handSkeleton else { return nil }
        let m = a.originFromAnchorTransform
        let palmJoint = skel.joint(.middleFingerMetacarpal)
        let palmM = m * palmJoint.anchorFromJointTransform
        let rot3 = simd_float3x3(
            SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        )
        return Pose(
            wrist: SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z),
            palm: SIMD3(palmM.columns.3.x, palmM.columns.3.y, palmM.columns.3.z),
            rotation: simd_normalize(simd_quatf(rot3))
        )
    }
}
