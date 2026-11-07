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
    private struct CalSample {
        var leadPos: SIMD3<Float>
        var leadRot: simd_quatf
        var trailPos: SIMD3<Float>
        var t: Double
    }
    private var calSamples: [CalSample] = []
    private var lastLockAttempt = -Double.infinity
    private var relockSeen = 0
    private var lockNote = "hold still at address"
    static let minLockFrames = 8
    static let maxLockSpread: Float = 12 * .pi / 180  // frames must agree within this
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
        calSamples.removeAll()
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

        if appModel.relockToken != relockSeen {
            relockSeen = appModel.relockToken
            reset()
            lockNote = "re-lock: hold still at address"
        }

        // lock the club to ur hands: collect every frame both hands are seen while ur still at
        // address (clasped hands hide the lead hand most frames, thats fine, unseen frames dont
        // reset it), then lock off the AVERAGE once theyre steady. one frame used to be enough +
        // a half hidden frame w/ a flipped palm would lock the club sideways
        // locks ONCE. how the club sits in ur hand doesnt change between swings, + relocking every
        // time u stood still w/ ur hands together (watching the ball, waiting for it to come
        // back) aimed the shaft at the ball from wherever ur hands were. the error stacked up
        // shot after shot till the club sat on the back of ur hand. re-lock button to redo it
        if calib == nil, let lp = hands.leadPos, let lr = hands.leadRot, let tp = hands.trailPos {
            let moved = lastLead.map { simd_distance($0, lp) } ?? 1
            lastLead = lp
            let swinging = live.isFresh && abs(live.watchAngle) > 0.15
            let together = simd_distance(lp, tp) < 0.15
            if moved < 0.006 && together && !swinging && ballIsIdle {
                calSamples.append(CalSample(leadPos: lp, leadRot: lr, trailPos: tp, t: now))
                calSamples.removeAll { $0.t < now - 1.0 }
                tryLock(ball: ballW, target: target, backend: tracking.backend, lead: leadHand, now: now)
            } else {
                calSamples.removeAll()
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
                // just came back from fallback -> slide the free club onto the hand for a beat.
                // only start it once (during the blend source still reads .fallback)
                if blendFrom == nil && (self.source == .fallback || self.source == .frozen) {
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
        } else if let last = lastPose {
            // hands lost + no watch motion: hold the club where ur hands last were. used to give up
            // after 0.25s + show the watch putter/club sitting at the ball instead (the "snap to ball")
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
        // the old watch lever club only shows when the hand club cant. in hands only mode
        // it stays hidden (it'd pop up in the wrong spot)
        rig?.root.isEnabled = s == .none && appModel?.clubSource != .hands
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

    private static func angle(_ a: simd_quatf, _ b: simd_quatf) -> Float {
        2 * acos(min(1, abs(simd_dot(a.vector, b.vector))))
    }

    private func tryLock(ball: SIMD3<Float>, target: SIMD3<Float>, backend: HandTracking.Backend, lead: Handedness, now: Double) {
        guard calSamples.count >= Self.minLockFrames, let first = calSamples.first, let last = calSamples.last,
              last.t - first.t >= 0.5, now - lastLockAttempt > 0.5 else { return }
        lastLockAttempt = now

        // average rotation (same hemisphere first) + positions
        let ref = first.leadRot.vector
        var acc = SIMD4<Float>()
        var leadSum = SIMD3<Float>(), trailSum = SIMD3<Float>()
        for c in calSamples {
            acc += simd_dot(c.leadRot.vector, ref) < 0 ? -c.leadRot.vector : c.leadRot.vector
            leadSum += c.leadPos
            trailSum += c.trailPos
        }
        let n = Float(calSamples.count)
        let avgRot = simd_normalize(simd_quatf(vector: simd_normalize(acc)))
        let spread = calSamples.map { Self.angle($0.leadRot, avgRot) }.max() ?? 0
        guard spread < Self.maxLockSpread else {
            lockNote = String(format: "hands not steady (%.0f°)", spread * 180 / .pi)
            calSamples.removeFirst(calSamples.count / 2)
            return
        }
        // golf grip: the BACK of the lead hand faces the target, so the palm (+y) cant point at it.
        // if it does the tracker flipped the half hidden hand, dont lock on that
        var palm = avgRot.act([0, 1, 0])
        palm.y = 0
        if simd_length(palm) > 0.3, simd_dot(simd_normalize(palm), target) > 0.35 {
            lockNote = "lead palm read backwards, open ur grip a sec"
            calSamples.removeAll()
            return
        }

        let avgLead = leadSum / n
        let grip = (avgLead + trailSum / n) / 2
        // only lock from a real setup over the ball, the lock assumes the clubhead is AT the ball
        let toBall = ball - grip
        let reach = simd_length(toBall)
        let flat = simd_length(SIMD2(toBall.x, toBall.z))
        let reachOK = putter ? (0.45...1.05) ~= reach : (0.55...1.25) ~= reach
        guard reachOK, grip.y - ball.y > 0.35, flat < 0.9 else {
            lockNote = "set up over the ball to lock"
            calSamples.removeAll()
            return
        }
        let (cand, length) = makeCalibration(leadPos: avgLead, leadRot: avgRot, grip: grip, ball: ball,
                                             target: target, backend: backend, lead: lead)
        calSamples.removeAll()
        apply(cand, length: length)
        lockNote = "locked ✓"
    }

    private func makeCalibration(leadPos: SIMD3<Float>, leadRot: simd_quatf, grip: SIMD3<Float>, ball: SIMD3<Float>,
                                 target: SIMD3<Float>, backend: HandTracking.Backend, lead: Handedness) -> (Calibration, Float) {
        let toBall = ball - grip
        let L = min(max(simd_length(toBall), 0.5), 1.3)
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
        return (c, L)
    }

    private func apply(_ c: Calibration, length: Float) {
        for m in [leftClub, rightClub, freeClub] { m.build(length: length) }
        calib = c
        // anchored: the club lives in the palm anchors frame
        let club = c.lead == .left ? leftClub : rightClub
        club.root.position = c.localPos
        club.root.orientation = c.localRot
        posFilter.reset()
    }

    // clubhead crosses the ball going toward the target -> launch now, watch refines it after.
    // hand tracking jitters a few mm/frame + the putter face sits 3.6cm behind the ball, so a
    // wobble used to cross the ball line + frame to frame speed turned it into a rocket. now it
    // needs a real backstroke first + speed is averaged over ~40ms
    private var headTrail: [(t: Double, s: Float, pos: SIMD3<Float>)] = []
    static let speedWindow = 0.04

    private func checkContact(pose: (pos: SIMD3<Float>, rot: simd_quatf), ball: SIMD3<Float>, target: SIMD3<Float>, dt: Float, now: Double) {
        let length = freeClub.length
        let head = pose.pos + pose.rot.act([0, -length, 0])
        let sNow = simd_dot(head - ball, target)
        defer {
            prevHead = head
            headTrail.append((now, sNow, head))
            headTrail.removeAll { $0.t < now - 0.8 }
        }
        guard let prev = prevHead, dt > 0, now - lastContact > 1.5, ballIsIdle else { return }
        let sPrev = simd_dot(prev - ball, target)
        guard sPrev < 0 && sNow >= 0 else { return }
        // where it crossed, how far from the ball center (sideways + up/down)
        let u = sPrev / (sPrev - sNow)
        let cross = prev + (head - prev) * u
        let off = cross - ball - simd_dot(cross - ball, target) * target
        guard simd_length(off) < (putter ? 0.08 : 0.15) else { return }
        // came from a real backstroke in the last 0.8s?
        let deepest = headTrail.map(\.s).min() ?? 0
        guard deepest < (putter ? -0.06 : -0.15) else { return }
        // speed toward the target over the last ~40ms, not one jittery frame
        guard let ref = headTrail.last(where: { $0.t <= now - Self.speedWindow }) ?? headTrail.first, now > ref.t else { return }
        let speed = (sNow - ref.s) / Float(now - ref.t)
        guard speed > minContactSpeed else { return }

        // face angle: where the face normal points vs the target, + = right. capped, a few
        // degrees off on a putt is already a miss
        var n = pose.rot.act([0, 0, -1])
        n.y = 0
        n = simd_normalize(n)
        let right = simd_cross(target, [0, 1, 0])
        let cap: Float = putter ? 8 : 20
        let faceDeg = min(max(atan2(simd_dot(n, right), simd_dot(n, target)) * 180 / .pi, -cap), cap)
        lastContact = now
        lastContactSpeed = speed
        headTrail.removeAll()
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
        var s = "\(source.rawValue) · \(lockNote)"
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
