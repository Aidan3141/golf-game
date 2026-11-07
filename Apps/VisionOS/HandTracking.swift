import ARKit
import Foundation
import QuartzCore
import RealityKit
import simd

// hand tracking for the whole app, 2 backends (only one runs at a time):
//  - anchored (default): realitykit AnchorEntity(.hand, trackingMode: .predicted). the renderer
//    puts the club on the hand pose predicted for when the frame actually hits ur eyes. a
//    SpatialTrackingSession lets us read those anchor transforms for calibration + contact
//  - manual: arkit HandTrackingProvider + handAnchors(at: now + lookahead). we guess the
//    display time (realitykit doesnt tell us), so this one lags more. kept to compare
@MainActor
final class HandTracking {
    enum Backend: String, CaseIterable {
        case anchored = "System predicted"
        case manual = "Manual"
    }

    struct Pose {
        var wrist: SIMD3<Float>
        var palm: SIMD3<Float>  // middle finger metacarpal, ~center of the grip
        var rotation: simd_quatf  // world from hand
    }

    enum State: Equatable {
        case off, starting, running, unsupported, denied
    }

    private(set) var state = State.off
    private(set) var backend = Backend.anchored

    private var arSession: ARKitSession?
    private var provider: HandTrackingProvider?
    private var spatial: SpatialTrackingSession?
    private var updatesTask: Task<Void, Never>?

    // manual only: how far ahead to predict (s). ~display latency, tune in the headset
    var lookahead = 0.06

    // manual only diag: how often arkit sends hands + how old the newest one is
    private(set) var updateHz = 0.0
    private(set) var dataAge: Double?
    private(set) var highFidelity = false
    private var updatesInWindow = 0
    private var windowStart = 0.0

    var isRunning: Bool { state == .running }

    func start(_ backend: Backend) {
        stop()
        self.backend = backend
        guard HandTrackingProvider.isSupported else {
            state = .unsupported
            return
        }
        state = .starting
        switch backend {
        case .anchored:
            let s = SpatialTrackingSession()
            spatial = s
            Task {
                let missing = await s.run(SpatialTrackingSession.Configuration(tracking: [.hand]))
                guard self.spatial === s else { return }
                self.state = missing?.anchor.contains(.hand) == true ? .denied : .running
            }
        case .manual:
            let s = ARKitSession()
            let p = HandTrackingProvider()
            arSession = s
            provider = p
            Task {
                do {
                    try await s.run([p])
                    guard self.provider === p else { return }
                    self.state = .running
                    self.watchUpdates(p)
                } catch {
                    self.state = .denied
                }
            }
        }
    }

    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        arSession?.stop()
        arSession = nil
        provider = nil
        if let s = spatial {
            Task { await s.stop() }
        }
        spatial = nil
        dataAge = nil
        updateHz = 0
        state = .off
    }

    // manual: predicted poses for (now + lookahead). anchored mode reads the anchors instead
    func predicted() -> (left: Pose?, right: Pose?) {
        guard backend == .manual, state == .running, let provider else { return (nil, nil) }
        let now = CACurrentMediaTime()
        let pair = provider.handAnchors(at: now + lookahead)
        let latest = provider.latestAnchors
        if let a = latest.leftHand ?? latest.rightHand {
            dataAge = now - a.timestamp
            highFidelity = a.fidelity == .high
        }
        return (Self.pose(pair.leftHand), Self.pose(pair.rightHand))
    }

    // count arkit updates/s so we know the real tracking rate
    private func watchUpdates(_ p: HandTrackingProvider) {
        updatesTask = Task {
            for await _ in p.anchorUpdates {
                self.updatesInWindow += 1
                let now = CACurrentMediaTime()
                if now - self.windowStart >= 1 {
                    // 2 hands -> 2 updates per frame
                    self.updateHz = Double(self.updatesInWindow) / (now - self.windowStart) / 2
                    self.updatesInWindow = 0
                    self.windowStart = now
                }
            }
        }
    }

    private static func pose(_ a: HandAnchor?) -> Pose? {
        guard let a, a.isTracked, let skel = a.handSkeleton else { return nil }
        let m = a.originFromAnchorTransform
        let palmJoint = skel.joint(.middleFingerMetacarpal)
        let palmM = m * palmJoint.anchorFromJointTransform
        return Pose(
            wrist: SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z),
            palm: SIMD3(palmM.columns.3.x, palmM.columns.3.y, palmM.columns.3.z),
            rotation: rotation(of: m)
        )
    }

    static func rotation(of m: simd_float4x4) -> simd_quatf {
        let r = simd_float3x3(
            SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        )
        return simd_normalize(simd_quatf(r))
    }
}
