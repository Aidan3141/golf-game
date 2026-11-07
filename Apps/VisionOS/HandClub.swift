import Foundation
import RealityKit
import SwingKit
import UIKit

// club geometry: grip at origin, shaft down -y, head at -y*len, face points -z
@MainActor
final class ClubModel {
    let root = Entity()
    private(set) var length: Float = 0
    private let putter: Bool

    init(putter: Bool) {
        self.putter = putter
        build(length: putter ? 0.85 : 0.95)
    }

    func build(length L: Float) {
        guard abs(L - length) > 0.02 else { return }
        length = L
        root.children.removeAll()
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
        root.addChild(grip)
        root.addChild(shaft)
        root.addChild(head)
    }
}

// club stuck to ur real hands. calibrated at address (grip -> ball, face -> target), stored in
// the lead hands frame. then:
//  - anchored (default): the club is a child of an AnchorEntity on ur lead palm w/ .predicted
//    tracking, so the RENDERER moves it to the hand pose predicted for display time. no app lag
//  - manual: we place a world club ourselves from arkit handAnchors(at: now + lookahead)
// if the lead hand drops out (top of backswing, blur at impact) the last pose keeps swinging
// around the watch lever axis by how much the (dead reckoned) watch angle moved
@MainActor
final class HandClub {
    enum Source: String {
        case anchored, manual, fallback, frozen, none
    }

    // anchors on both palms, added to the realityview content by the view. lead one shows the club
    let leftAnchor = AnchorEntity(.hand(.left, location: .palm), trackingMode: .predicted)
    let rightAnchor = AnchorEntity(.hand(.right, location: .palm), trackingMode: .predicted)
    private let leftClub: ClubModel
    private let rightClub: ClubModel
    // world space club for manual mode + fallback + blends
    let freeRoot = Entity()
    // never disabled, carries the HandClubComponent so the system keeps ticking even when
    // every club is hidden (disabled entities may not get system updates)
    let driver = Entity()
    private let freeClub: ClubModel

    weak var ball: Entity?
    weak var sceneRoot: Entity?
    weak var rig: ClubRig?
    weak var appModel: AppModel?
    var minContactSpeed: Float = 1.5  // m/s clubhead, putting lowers this
    private let putter: Bool

    private struct Calibration {
        var backend: HandTracking.Backend
        var lead: Handedness
        var localRot: simd_quatf  // club rot in the lead hand frame
        var localPos: SIMD3<Float>  // grip in the lead hand frame
    }
    private var calib: Calibration?
    private var stillSince: Double?
    private var lastLead: SIMD3<Float>?
    private var lastTracked = -Double.infinity
    private var lastPose: (pos: SIMD3<Float>, rot: simd_quatf)?
    private var leverAtTrack: Float = 0
    private var prevHead: SIMD3<Float>?
    private var lastContact = -Double.infinity
    private var source = Source.none
    private var blendFrom: (pos: SIMD3<Float>, rot: simd_quatf)?
    private var blendStart = 0.0
    static let blendTime = 0.08

    // manual mode smoothing
    private var posFilter = OneEuroFilter3()
    private var rotFilters = [OneEuroFilter](repeating: OneEuroFilter(), count: 4)
    private var lastRot = simd_quatf(angle: 0, axis: [0, 1, 0])

    // diag
    private var phaseCounts: [SwingPhase: (tracked: Int, total: Int)] = [:]
    private var lastPhase = SwingPhase.idle
    private var lastContactSpeed: Float?
    private var statsAt = 0.0

    init(putter: Bool) {
        self.putter = putter
        leftClub = ClubModel(putter: putter)
        rightClub = ClubModel(putter: putter)
        freeClub = ClubModel(putter: putter)
        leftAnchor.addChild(leftClub.root)
        rightAnchor.addChild(rightClub.root)
        freeRoot.addChild(freeClub.root)
        leftClub.root.isEnabled = false
        rightClub.root.isEnabled = false
        freeRoot.isEnabled = false
    }

    var isActive: Bool { source != .none }

    func reset() {
        calib = nil
        lastPose = nil
        stillSince = nil
        posFilter.reset()
        for i in 0..<4 { rotFilters[i].reset() }
        hideAll()
        rig?.root.isEnabled = true
    }

    private func hideAll() {
        leftClub.root.isEnabled = false
        rightClub.root.isEnabled = false
        freeRoot.isEnabled = false
    }

    // MARK: per frame

    private struct HandFrame {
        var leadPos: SIMD3<Float>?
        var leadRot: simd_quatf?
        var trailPos: SIMD3<Float>?
        var leftPos: SIMD3<Float>?
        var rightPos: SIMD3<Float>?
    }

    private func readHands(_ tracking: HandTracking, lead: Handedness) -> HandFrame {
        var f = HandFrame()
        switch tracking.backend {
        case .anchored:
            func read(_ a: AnchorEntity) -> (SIMD3<Float>, simd_quatf)? {
                guard a.isAnchored else { return nil }
                let p = a.position(relativeTo: nil)
                // transforms read as zero if the tracking session isnt authorized
                guard simd_length(p) > 0.001 else { return nil }
                return (p, a.orientation(relativeTo: nil))
            }
            let l = tracking.isRunning ? read(leftAnchor) : nil
            let r = tracking.isRunning ? read(rightAnchor) : nil
            f.leftPos = l?.0
            f.rightPos = r?.0
            let leadP = lead == .left ? l : r
            f.leadPos = leadP?.0
            f.leadRot = leadP?.1
            f.trailPos = lead == .left ? r?.0 : l?.0
        case .manual:
            let hands = tracking.predicted()
            f.leftPos = hands.left?.palm
            f.rightPos = hands.right?.palm
            let leadP = lead == .left ? hands.left : hands.right
            f.leadPos = leadP?.palm
            f.leadRot = leadP?.rotation
            f.trailPos = lead == .left ? hands.right?.palm : hands.left?.palm
        }
        return f
    }

    func tick(dt: Float) {
        guard let appModel, let ball, let sceneRoot else { return }
        let source = appModel.clubSource
        let tracking = appModel.handTracking
        let now = ProcessInfo.processInfo.systemUptime
        // righty: left hand leads
        let leadHand: Handedness = appModel.handedness == .right ? .left : .right
        let hands = readHands(tracking, lead: leadHand)
        let live = appModel.liveClub

        appModel.addressCheck.update(left: hands.leftPos, right: hands.rightPos)
        countPhase(live.isFresh ? live.phase : .idle, tracked: hands.leadPos != nil)

        let ballW = ball.position(relativeTo: nil)
        var target = sceneRoot.convert(direction: [0, 0, -1], to: nil)
        target.y = 0
        target = simd_normalize(target)

        if let c = calib, c.backend != tracking.backend || c.lead != leadHand {
            reset()  // backend or hand changed, calibrate again
        }

        guard source != .watch else {
            show(.none)
            log(hands: hands, pose: nil)
            updateStats(now)
            return
        }

        // calibrate when both hands sit still at address (+ watch isnt mid swing)
        if let lp = hands.leadPos, let lr = hands.leadRot, let tp = hands.trailPos {
            let moved = lastLead.map { simd_distance($0, lp) } ?? 1
            lastLead = lp
            let swinging = live.isFresh && abs(live.watchAngle) > 0.15
            let together = simd_distance(lp, tp) < 0.15
            if moved < 0.004 && together && !swinging {
                stillSince = stillSince ?? now
            } else {
                stillSince = nil
            }
            if let s = stillSince, now - s > 0.5, ballIsIdle {
                calibrate(leadPos: lp, leadRot: lr, grip: (lp + tp) / 2, ball: ballW, target: target,
                          backend: tracking.backend, lead: leadHand)
                stillSince = now + 1  // dont redo every frame, again in ~1.5s if still still
            }
        }

        guard let calib else {
            show(.none)
            log(hands: hands, pose: nil)
            updateStats(now)
            return
        }

        var pose: (pos: SIMD3<Float>, rot: simd_quatf)?
        if let lp = hands.leadPos, let lr = hands.leadRot {
            var p = (pos: lp + lr.act(calib.localPos), rot: lr * calib.localRot)
            if tracking.backend == .manual { p = smooth(p, now: now) }
            pose = p
            lastPose = p
            lastTracked = now
            leverAtTrack = live.leverAngle
            if tracking.backend == .anchored {
                // just came back from fallback -> slide the free club onto the hand for a beat
                if self.source == .fallback || self.source == .frozen {
                    blendFrom = (freeRoot.position, freeRoot.orientation)
                    blendStart = now
                }
                if let from = blendFrom, now - blendStart < Self.blendTime {
                    let u = Float((now - blendStart) / Self.blendTime)
                    placeFree((mix(from.pos, p.pos, t: u), simd_slerp(from.rot, p.rot, u)))
                    show(.fallback)
                } else {
                    blendFrom = nil
                    show(.anchored, lead: leadHand)
                }
            } else {
                placeFree(p)
                show(.manual)
            }
        } else if source == .hybrid, let last = lastPose, live.isFresh, let rig {
            // hands lost: swing the last pose around the watch lever axis by how much the
            // (dead reckoned) watch angle moved since we last saw the hands
            let delta = live.leverAngle - leverAtTrack
            let axisW = simd_normalize(rig.root.convert(direction: rig.axis, to: nil))
            let pivotW = rig.root.position(relativeTo: nil)
            let q = simd_quatf(angle: delta, axis: axisW)
            let p = (pos: pivotW + q.act(last.pos - pivotW), rot: q * last.rot)
            pose = p
            placeFree(p)
            show(.fallback)
        } else if let last = lastPose, now - lastTracked < 0.25 {
            pose = last
            placeFree(last)
            show(.frozen)
        } else {
            show(.none)
        }

        if let pose { checkContact(pose: pose, ball: ballW, target: target, dt: dt, now: now) }
        log(hands: hands, pose: pose)
        updateStats(now)
    }

    private func placeFree(_ p: (pos: SIMD3<Float>, rot: simd_quatf)) {
        freeRoot.position = p.pos
        freeRoot.orientation = p.rot
    }

    private func show(_ s: Source, lead: Handedness = .left) {
        source = s
        leftClub.root.isEnabled = s == .anchored && lead == .left
        rightClub.root.isEnabled = s == .anchored && lead == .right
        freeRoot.isEnabled = s == .manual || s == .fallback || s == .frozen
        rig?.root.isEnabled = s == .none
    }

    // manual mode only: 1€ filter, smoothing 0 = off
    private func smooth(_ p: (pos: SIMD3<Float>, rot: simd_quatf), now: Double) -> (pos: SIMD3<Float>, rot: simd_quatf) {
        let s = appModel?.handSmoothing ?? 0
        guard s > 0.01 else { return p }
        let minCutoff = 8 * (1 - s) + 0.6 * s
        let beta = 3 * (1 - s) + 0.4 * s
        posFilter.set(minCutoff: minCutoff, beta: beta)
        let fp = posFilter.filter(SIMD3<Double>(p.pos), t: now)
        // keep quaternions on the same hemisphere or the filter averages through garbage
        var q = p.rot.vector
        if simd_dot(q, lastRot.vector) < 0 { q = -q }
        var out = SIMD4<Float>()
        for i in 0..<4 {
            rotFilters[i].minCutoff = minCutoff
            rotFilters[i].beta = beta
            out[i] = Float(rotFilters[i].filter(Double(q[i]), t: now))
        }
        let fq = simd_quatf(vector: out)
        lastRot = simd_normalize(fq)
        return (SIMD3<Float>(fp), lastRot)
    }

    private var ballIsIdle: Bool {
        guard let ball else { return false }
        return !ball.components.has(BallFlightComponent.self) && !ball.components.has(PuttRollComponent.self)
    }

    private func calibrate(leadPos: SIMD3<Float>, leadRot: simd_quatf, grip: SIMD3<Float>, ball: SIMD3<Float>,
                           target: SIMD3<Float>, backend: HandTracking.Backend, lead: Handedness) {
        let toBall = ball - grip
        let L = min(max(simd_length(toBall), 0.5), 1.3)
        for c in [leftClub, rightClub, freeClub] { c.build(length: L) }
        let d = simd_normalize(toBall)
        // club frame in world at address: -y along the shaft to the ball, -z = face toward target
        let y = -d
        let tPerp = simd_normalize(target - simd_dot(target, d) * d)
        let z = -tPerp
        let x = simd_normalize(simd_cross(y, z))
        let q0 = simd_normalize(simd_quatf(simd_float3x3(x, y, simd_cross(x, y))))
        let c = Calibration(backend: backend, lead: lead,
                            localRot: leadRot.inverse * q0,
                            localPos: leadRot.inverse.act(grip - leadPos))
        calib = c
        // anchored: the club lives in the palm anchors frame
        let club = lead == .left ? leftClub : rightClub
        club.root.position = c.localPos
        club.root.orientation = c.localRot
        posFilter.reset()
    }

    // clubhead crosses the ball going toward the target -> launch now, watch refines it after
    private func checkContact(pose: (pos: SIMD3<Float>, rot: simd_quatf), ball: SIMD3<Float>, target: SIMD3<Float>, dt: Float, now: Double) {
        let length = freeClub.length
        let head = pose.pos + pose.rot.act([0, -length, 0])
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
        var n = pose.rot.act([0, 0, -1])
        n.y = 0
        n = simd_normalize(n)
        let right = simd_cross(target, [0, 1, 0])
        let faceDeg = atan2(simd_dot(n, right), simd_dot(n, target)) * 180 / .pi
        lastContact = now
        lastContactSpeed = speed
        appModel?.contact(headSpeed: Double(speed), faceDegrees: Double(faceDeg))
    }

    // MARK: diag

    // tracked % per watch phase, reset every time u address
    private func countPhase(_ p: SwingPhase, tracked: Bool) {
        if p == .address && lastPhase != .address { phaseCounts.removeAll() }
        lastPhase = p
        var c = phaseCounts[p] ?? (0, 0)
        c.total += 1
        if tracked { c.tracked += 1 }
        phaseCounts[p] = c
    }

    private func log(hands: HandFrame, pose: (pos: SIMD3<Float>, rot: simd_quatf)?) {
        guard let appModel else { return }
        let live = appModel.liveClub
        let head = pose.map { $0.pos + $0.rot.act([0, -freeClub.length, 0]) }
        appModel.swingLogger.record(SwingLogger.Frame(
            t: ProcessInfo.processInfo.systemUptime,
            src: source.rawValue,
            lead: hands.leadPos != nil,
            trail: hands.trailPos != nil,
            grip: pose.map { [$0.pos.x, $0.pos.y, $0.pos.z] },
            head: head.map { [$0.x, $0.y, $0.z] },
            watch: live.sample?.angle,
            shown: live.sample == nil ? nil : live.displayAngle(),
            age: live.sample?.time.map { ProcessInfo.processInfo.systemUptime - $0 },
            phase: live.phase.rawValue
        ))
    }

    private func updateStats(_ now: Double) {
        guard now - statsAt > 0.5, let appModel else { return }
        statsAt = now
        func pct(_ p: SwingPhase) -> String {
            guard let c = phaseCounts[p], c.total > 0 else { return "–" }
            return "\(100 * c.tracked / c.total)"
        }
        var s = "\(source.rawValue) · " + (calib == nil ? "hold still at address" : "calibrated ✓")
        s += " · seen addr \(pct(.address)) back \(pct(.backswing)) down \(pct(.downswing)) thru \(pct(.followThrough))%"
        if let c = lastContactSpeed { s += String(format: " · contact %.1f m/s", c) }
        let tracking = appModel.handTracking
        if tracking.backend == .manual, let age = tracking.dataAge {
            s += String(format: " · arkit %.0fHz %.0fms old%@", tracking.updateHz, age * 1000, tracking.highFidelity ? " hi-fi" : "")
        }
        if appModel.handStats != s { appModel.handStats = s }
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
