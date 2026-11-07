import Foundation
import RealityKit
import SwingKit

// latest club reading from the watch stream. plain class, not observed, the systems read it
// every frame. instead of drawing the last angle we got (which is ~50-150ms old by now) it
// dead reckons: angle + angular velocity x (display time - sample time). clocks are synced
// watch -> phone -> headset so the sample time is real
@MainActor
final class LiveClub {
    private(set) var sample: ClubSample?
    private(set) var receivedAt = -Double.infinity

    // tuning, the window can change these live
    var extrapolate = true
    var displayLead = 0.035  // s from our update to photons, guess, tune in the headset
    var maxHorizon = 0.25

    static let staleAfter = 0.6  // s w/o updates -> club eases back to address

    func update(_ s: ClubSample) {
        sample = s
        receivedAt = ProcessInfo.processInfo.systemUptime
    }

    var phase: SwingPhase { sample?.phase ?? .idle }
    var watchAngle: Double { sample?.angle ?? 0 }  // raw, last one we got

    var isFresh: Bool {
        ProcessInfo.processInfo.systemUptime - receivedAt < Self.staleAfter
    }

    // the angle that should be on screen when this frame shows up
    func displayAngle(now: Double = ProcessInfo.processInfo.systemUptime) -> Double {
        guard var s = sample else { return 0 }
        guard extrapolate else { return s.angle }
        // not synced yet: pretend it was measured when it got here (under predicts, never over)
        if s.time == nil { s.time = receivedAt }
        return s.predictedAngle(at: now + displayLead, maxHorizon: maxHorizon)
    }

    // wrist turns ~130 at the top + ~-70 at the finish, the club goes way further
    static func lever(_ watchAngle: Double) -> Float {
        let a = Float(watchAngle)
        let lever = a >= 0 ? a * 1.45 : a * 2.6
        return min(max(lever, -3.6), 3.6)
    }

    var leverAngle: Float { Self.lever(displayAngle()) }
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
                let live = c.live.live
                let target = live.isFresh ? live.leverAngle : 0
                // prediction already covers the lag, this just softens the step when a new
                // sample corrects it (~25ms). slow drift home when it goes stale
                let rate: Float = live.isFresh ? 40 : 3
                c.shown += (target - c.shown) * min(1, rate * dt)
                c.rig.rig.setAngle(c.shown)
                e.components.set(c)
            }
        }
    }
}
