import Foundation
import RealityKit
import SwingKit
import UIKit

// club stuck to ur real hands. calibrated at address (grip -> ball), then every frame:
// grip = lead hand pose + fixed offset, orientation = lead hand rotation x fixed offset.
// so wrist twist = club twist, no watch lag. if tracking drops (top of backswing, blur at impact)
// the watch angle carries it from the last tracked pose
@MainActor
final class HandClub {
    let root = Entity()  // world space, NOT under the range root
    private let model = Entity()
    private(set) var length: Float = 0
    private var putter = false

    // set up by the view
    weak var ball: Entity?
    weak var sceneRoot: Entity?
    weak var rig: ClubRig?
    weak var appModel: AppModel?
    var minContactSpeed: Float = 1.5  // m/s clubhead, putting lowers this

    private struct Calibration {
        var offsetRot: simd_quatf  // lead hand rot -> club rot
        var gripInLead: SIMD3<Float>  // grip point in lead hand frame
    }
    private var calib: Calibration?
    private var stillSince: Double?
    private var lastPalm: SIMD3<Float>?
    private var lastTracked = -Double.infinity
    private var lastPose: (pos: SIMD3<Float>, rot: simd_quatf)?
    private var leverAtTrack: Float = 0
    private var prevHead: SIMD3<Float>?
    private var lastContact = -Double.infinity

    // debug
    private var framesTotal = 0
    private var framesTracked = 0
    private var statsAt = 0.0
    private var lastContactSpeed: Float?

    init(putter: Bool) {
        self.putter = putter
        root.addChild(model)
        root.isEnabled = false
        build(length: putter ? 0.85 : 0.95)
    }

    var isActive: Bool { root.isEnabled }

    // grip at origin, shaft down -y, head at -y*len, face points -z
    private func build(length L: Float) {
        guard abs(L - length) > 0.02 else { return }
        length = L
        model.children.removeAll()
        let grip = ModelEntity(mesh: .generateCylinder(height: 0.26, radius: 0.012),
                               materials: [SimpleMaterial(color: UIColor(white: 0.08, alpha: 1), roughness: 0.8, isMetallic: false)])
        grip.position = [0, -0.13, 0]
        let shaftLen = L - 0.24
        let shaft = ModelEntity(mesh: .generateCylinder(height: shaftLen, radius: 0.0055),
                                materials: [SimpleMaterial(color: UIColor(white: 0.75, alpha: 1), roughness: 0.2, isMetallic: true)])
        shaft.position = [0, -0.24 - shaftLen / 2, 0]
        let head = ModelEntity(
            mesh: putter
                ? .generateBox(width: 0.11, height: 0.026, depth: 0.03, cornerRadius: 0.005)
                : .generateBox(width: 0.078, height: 0.046, depth: 0.02, cornerRadius: 0.006),
            materials: [SimpleMaterial(color: UIColor(white: putter ? 0.3 : 0.85, alpha: 1), roughness: 0.25, isMetallic: true)]
        )
        head.position = [0, -L, 0]
        head.components.set(GroundingShadowComponent(castsShadow: true))
        model.addChild(grip)
        model.addChild(shaft)
        model.addChild(head)
    }

    func reset() {
        calib = nil
        lastPose = nil
        root.isEnabled = false
        rig?.root.isEnabled = true
    }

    // MARK: per frame

    func tick(dt: Float) {
        guard let appModel, let ball, let sceneRoot else { return }
        let source = appModel.clubSource
        let now = ProcessInfo.processInfo.systemUptime
        let hands = appModel.handTracking.predicted()
        let rightHanded = appModel.handedness == .right
        let lead = rightHanded ? hands.left : hands.right
        let trail = rightHanded ? hands.right : hands.left

        appModel.addressCheck.update(left: hands.left?.wrist, right: hands.right?.wrist)
        framesTotal += 1
        if lead != nil { framesTracked += 1 }

        let ballW = ball.position(relativeTo: nil)
        var target = sceneRoot.convert(direction: [0, 0, -1], to: nil)
        target.y = 0
        target = simd_normalize(target)

        guard source != .watch else {
            root.isEnabled = false
            rig?.root.isEnabled = true
            updateStats(now)
            return
        }

        // calibrate when both hands sit still at address (+ watch isnt mid swing)
        if let l = lead, let t = trail {
            let grip = (l.palm + t.palm) / 2
            let moved = lastPalm.map { simd_distance($0, l.palm) } ?? 1
            lastPalm = l.palm
            let swinging = appModel.liveClub.isFresh && abs(appModel.liveClub.watchAngle) > 0.15
            let together = simd_distance(l.palm, t.palm) < 0.15
            if moved < 0.004 && together && !swinging {
                stillSince = stillSince ?? now
            } else {
                stillSince = nil
            }
            if let s = stillSince, now - s > 0.5, ballIsIdle {
                calibrate(lead: l, grip: grip, ball: ballW, target: target)
                stillSince = now + 1  // dont redo every frame, again in ~1.5s if still still
            }
        }

        guard let calib else {
            root.isEnabled = false
            rig?.root.isEnabled = true
            updateStats(now)
            return
        }

        if let l = lead {
            let rot = l.rotation * calib.offsetRot
            let pos = l.wrist + l.rotation.act(calib.gripInLead)
            root.position = pos
            root.orientation = rot
            lastPose = (pos, rot)
            lastTracked = now
            leverAtTrack = appModel.liveClub.leverAngle
        } else if source == .hybrid, let last = lastPose, appModel.liveClub.isFresh, let rig {
            // hands lost, swing the last pose around the watch lever axis by how much the watch moved
            let delta = appModel.liveClub.leverAngle - leverAtTrack
            let axisW = simd_normalize(rig.root.convert(direction: rig.axis, to: nil))
            let pivotW = rig.root.position(relativeTo: nil)
            let q = simd_quatf(angle: delta, axis: axisW)
            root.position = pivotW + q.act(last.pos - pivotW)
            root.orientation = q * last.rot
        }

        let showing = now - lastTracked < (source == .hybrid ? 3 : 0.3)
        root.isEnabled = showing
        rig?.root.isEnabled = !showing

        if showing { checkContact(ball: ballW, target: target, dt: dt, now: now) }
        updateStats(now)
    }

    private var ballIsIdle: Bool {
        guard let ball else { return false }
        return !ball.components.has(BallFlightComponent.self) && !ball.components.has(PuttRollComponent.self)
    }

    private func calibrate(lead: HandTracking.Pose, grip: SIMD3<Float>, ball: SIMD3<Float>, target: SIMD3<Float>) {
        let toBall = ball - grip
        let L = min(max(simd_length(toBall), 0.5), 1.3)
        build(length: L)
        let d = simd_normalize(toBall)
        // club frame in world at address: -y along the shaft to the ball, -z = face toward target
        let y = -d
        let tPerp = simd_normalize(target - simd_dot(target, d) * d)
        let z = -tPerp
        let x = simd_normalize(simd_cross(y, z))
        let q0 = simd_normalize(simd_quatf(simd_float3x3(x, y, simd_cross(x, y))))
        calib = Calibration(
            offsetRot: lead.rotation.inverse * q0,
            gripInLead: lead.rotation.inverse.act(grip - lead.wrist)
        )
    }

    // clubhead crosses the ball going toward the target -> launch now, watch refines it after
    private func checkContact(ball: SIMD3<Float>, target: SIMD3<Float>, dt: Float, now: Double) {
        let head = root.position + root.orientation.act([0, -length, 0])
        defer { prevHead = head }
        guard let prev = prevHead, dt > 0, now - lastContact > 1.5, ballIsIdle else { return }
        let sPrev = simd_dot(prev - ball, target)
        let sNow = simd_dot(head - ball, target)
        guard sPrev < 0 && sNow >= 0 else { return }
        // where it crossed, how far from the ball center (sideways + up/down)
        let u = sPrev / (sPrev - sNow)
        let cross = prev + (head - prev) * u
        let off = cross - ball - simd_dot(cross - ball, target) * target
        guard simd_length(off) < (putter ? 0.08 : 0.15) else { return }
        let speed = simd_dot(head - prev, target) / dt
        guard speed > minContactSpeed else { return }

        // face angle: where the face normal points vs the target, + = right
        var n = root.orientation.act([0, 0, -1])
        n.y = 0
        n = simd_normalize(n)
        let right = simd_cross(target, [0, 1, 0])
        let faceDeg = atan2(simd_dot(n, right), simd_dot(n, target)) * 180 / .pi
        lastContact = now
        lastContactSpeed = speed
        appModel?.contact(headSpeed: Double(speed), faceDegrees: Double(faceDeg))
    }

    private func updateStats(_ now: Double) {
        guard now - statsAt > 0.5, let appModel else { return }
        let pct = framesTotal > 0 ? 100 * framesTracked / framesTotal : 0
        var s = "hands \(pct)% · " + (calib == nil ? "hold still at address" : "calibrated ✓")
        if let c = lastContactSpeed { s += String(format: " · contact %.1f m/s", c) }
        if appModel.handStats != s { appModel.handStats = s }
        framesTotal = 0
        framesTracked = 0
        statsAt = now
    }
}

struct HandClubComponent: Component {
    let ref: HandClubRef
}

struct HandClubRef: @unchecked Sendable {
    let club: HandClub
}

struct HandClubSystem: System {
    static let query = EntityQuery(where: .has(HandClubComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let dt = Float(context.deltaTime)
        for e in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard let c = e.components[HandClubComponent.self] else { continue }
            MainActor.assumeIsolated { c.ref.club.tick(dt: dt) }
        }
    }
}
