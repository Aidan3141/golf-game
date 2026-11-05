import RealityKit
import SwingKit
import UIKit

// ghost club that swings next to the ball. its one rigid lever from the "chest" to the clubhead,
// rotating in a tilted swing plane that contains the target line. not real biomechanics, just reads ok
@MainActor
final class ClubRig {
    let root = Entity()
    private let lever = Entity()
    private(set) var axis = SIMD3<Float>(0, 0, 1)
    private var baseAxis = SIMD3<Float>(0, 0, 1)

    static let hands: Float = 0.38  // where grip starts along the lever
    private var lastSetup: (Handedness, SIMD3<Float>, Bool)?

    // same ball + club, just flip hands
    func setHand(_ hand: Handedness) {
        if let (_, ball, putter) = lastSetup {
            setUp(for: hand, ball: ball, putter: putter)
        } else {
            setUp(for: hand)
        }
    }

    // turn + slide a scene root so this club's pivot is where u stand, target off to ur lead side
    func firstPersonTransform(hand: Handedness) -> (orientation: simd_quatf, position: SIMD3<Float>) {
        let q = simd_quatf(angle: hand == .right ? .pi / 2 : -.pi / 2, axis: [0, 1, 0])
        let p = q.act(root.position)
        return (q, [-p.x, 0, -p.z])
    }
    static let shaftLength: Float = 0.86

    init() {
        root.addChild(lever)
        setUp(for: .right)
    }

    // golfer stands left of the ball (rh) or right (lh), chest ~1.1m up.
    // putter = closer to the ball (eyes over it), flat blade head
    func setUp(for hand: Handedness, ball: SIMD3<Float> = RangeScene.ballRestPosition, putter: Bool = false) {
        let side: Float = hand == .right ? -1 : 1
        let head = ball + [0, 0, 0.036]  // face sits just behind the ball
        let pivot = SIMD3<Float>(ball.x + side * (putter ? 0.32 : 0.55), putter ? 1.05 : 1.1, ball.z)
        let toHead = head - pivot
        let length = simd_length(toHead)
        let d = toHead / length

        root.position = pivot
        lever.children.removeAll()
        lever.orientation = simd_quatf(angle: 0, axis: [0, 1, 0])
        // n x d = +z so +angle swings the head away from target (backswing)
        baseAxis = simd_normalize(simd_cross(d, [0, 0, 1]))
        axis = baseAxis

        let grip = ModelEntity(
            mesh: .generateCylinder(height: 0.26, radius: 0.012),
            materials: [SimpleMaterial(color: UIColor(white: 0.08, alpha: 1), roughness: 0.8, isMetallic: false)]
        )
        grip.position = d * (length - Self.shaftLength + 0.13)
        grip.orientation = simd_quatf(from: [0, 1, 0], to: d)

        let shaft = ModelEntity(
            mesh: .generateCylinder(height: Self.shaftLength, radius: 0.0055),
            materials: [SimpleMaterial(color: UIColor(white: 0.75, alpha: 1), roughness: 0.2, isMetallic: true)]
        )
        shaft.position = d * (length - Self.shaftLength / 2)
        shaft.orientation = simd_quatf(from: [0, 1, 0], to: d)

        // iron head or putter blade, toe points away from golfer
        let clubHead = ModelEntity(
            mesh: putter
                ? .generateBox(width: 0.11, height: 0.026, depth: 0.03, cornerRadius: 0.005)
                : .generateBox(width: 0.078, height: 0.046, depth: 0.02, cornerRadius: 0.006),
            materials: [SimpleMaterial(color: UIColor(white: putter ? 0.3 : 0.85, alpha: 1), roughness: 0.25, isMetallic: true)]
        )
        clubHead.position = d * length + [-side * (putter ? 0.04 : 0.03), putter ? -0.005 : 0.006, 0]
        clubHead.components.set(GroundingShadowComponent(castsShadow: true))

        lever.addChild(grip)
        lastSetup = (hand, ball, putter)
        lever.addChild(shaft)
        lever.addChild(clubHead)
    }

    // tilt plane a bit so out-to-in / in-to-out is visible
    func setPath(_ pathBias: Double, hand: Handedness) {
        let sign: Float = hand == .right ? 1 : -1
        let tilt = simd_quatf(angle: Float(pathBias) * sign * 0.12, axis: [0, 1, 0])
        axis = simd_normalize(tilt.act(baseAxis))
    }

    func setAngle(_ angle: Float) {
        lever.orientation = simd_quatf(angle: angle, axis: axis)
    }
}

// drives one swing, launches the ball at impact
struct ClubSwingComponent: Component {
    var backswing: Float
    var downswing: Float
    var topAngle: Float
    var finishAngle: Float
    var flight: FlightResult
    var ball: Entity
    var effects: Entity
    var rig: ClubRigRef

    var elapsed: Float = 0
    var launched = false

    static let addressHold: Float = 0.5
    static let followThrough: Float = 0.45
    static let finishHold: Float = 1.2
    static let returnTime: Float = 0.7

    var impactTime: Float { Self.addressHold + backswing + downswing }
    var endTime: Float { impactTime + Self.followThrough + Self.finishHold + Self.returnTime }
}

// components need to be copyable, rig is a class so wrap it
struct ClubRigRef: @unchecked Sendable {
    let rig: ClubRig
}

struct ClubSwingSystem: System {
    static let query = EntityQuery(where: .has(ClubSwingComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let dt = Float(context.deltaTime)
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard var s = entity.components[ClubSwingComponent.self] else { continue }
            s.elapsed += dt
            let t = s.elapsed
            let angle = Self.angle(at: t, swing: s)

            MainActor.assumeIsolated {
                s.rig.rig.setAngle(angle)
                if !s.launched && t >= s.impactTime {
                    s.launched = true
                    s.ball.components.set(BallFlightComponent(flight: s.flight, effects: s.effects))
                }
                if t >= s.endTime {
                    s.rig.rig.setAngle(0)
                    entity.components.remove(ClubSwingComponent.self)
                } else {
                    entity.components.set(s)
                }
            }
        }
    }

    // angle timeline: hold, back (ease in-out), down (accelerates into impact), follow thru, hold, back to address
    static func angle(at t: Float, swing s: ClubSwingComponent) -> Float {
        var t = t - ClubSwingComponent.addressHold
        if t < 0 { return 0 }
        if t < s.backswing {
            let u = t / s.backswing
            return s.topAngle * (u * u * (3 - 2 * u))
        }
        t -= s.backswing
        if t < s.downswing {
            let u = t / s.downswing
            return s.topAngle * (1 - pow(u, 2.2))  // fastest right at impact
        }
        t -= s.downswing
        if t < ClubSwingComponent.followThrough {
            let u = t / ClubSwingComponent.followThrough
            return -s.finishAngle * (1 - (1 - u) * (1 - u))
        }
        t -= ClubSwingComponent.followThrough
        if t < ClubSwingComponent.finishHold { return -s.finishAngle }
        t -= ClubSwingComponent.finishHold
        let u = min(t / ClubSwingComponent.returnTime, 1)
        return -s.finishAngle * (1 - u * u * (3 - 2 * u))
    }
}

extension ClubSwingComponent {
    // slow wrist = short swing, fast = full
    init(shot: Shot, ball: Entity, effects: Entity, rig: ClubRig) {
        let power = Float(min(max((shot.swing.peakWristAngularVelocity - 8) / 20, 0), 1))
        self.init(
            backswing: Float(max(shot.swing.backswingDuration, 0.2)),
            downswing: Float(max(shot.swing.downswingDuration, 0.08)),
            topAngle: (110 + 85 * power) * .pi / 180,
            finishAngle: (120 + 85 * power) * .pi / 180,
            flight: shot.flight,
            ball: ball,
            effects: effects,
            rig: ClubRigRef(rig: rig)
        )
        // real swing already happened on ur wrist, jump straight to impact so the ball goes now
        if shot.live {
            elapsed = impactTime
        }
    }
}
