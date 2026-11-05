import Foundation
import RealityKit
import SwingKit

// latest club angle from the watch stream. plain class, not observed, the system reads it every frame
@MainActor
final class LiveClub {
    private(set) var watchAngle = 0.0  // rad from address
    private(set) var phase = SwingPhase.idle
    private(set) var updatedAt = -Double.infinity

    static let staleAfter = 0.6  // s w/o updates -> club eases back to address

    func update(angle: Double, phase: SwingPhase) {
        watchAngle = angle
        self.phase = phase
        updatedAt = ProcessInfo.processInfo.systemUptime
    }

    var isFresh: Bool {
        ProcessInfo.processInfo.systemUptime - updatedAt < Self.staleAfter
    }

    // wrist turns ~130 at the top + ~-70 at the finish, the club goes way further
    var leverAngle: Float {
        let a = Float(watchAngle)
        let lever = a >= 0 ? a * 1.45 : a * 2.6
        return min(max(lever, -3.6), 3.6)
    }
}

struct LiveClubComponent: Component {
    let live: LiveClubRef
    let rig: ClubRigRef
    var shown: Float = 0
}

struct LiveClubRef: @unchecked Sendable {
    let live: LiveClub
}

struct LiveClubSystem: System {
    static let query = EntityQuery(where: .has(LiveClubComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let dt = Float(context.deltaTime)
        for e in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            // slider replays drive the club themselves
            guard !e.components.has(ClubSwingComponent.self), var c = e.components[LiveClubComponent.self] else { continue }
            MainActor.assumeIsolated {
                let target = c.live.live.isFresh ? c.live.live.leverAngle : 0
                // fast follow while streaming, slow drift home when it goes stale
                let rate: Float = c.live.live.isFresh ? 25 : 3
                c.shown += (target - c.shown) * min(1, rate * dt)
                c.rig.rig.setAngle(c.shown)
                e.components.set(c)
            }
        }
    }
}
