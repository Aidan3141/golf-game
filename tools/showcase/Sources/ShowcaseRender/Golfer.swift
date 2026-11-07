import AppKit
import SceneKit
import simd

// glowing stick figure. head + hands are real (recorded), the rest is solved:
// neck/shoulders from the head, shoulder turn from where the hands are, elbows by 2 bone ik
// (bent the way the forearm points), legs planted from the address stance
final class Golfer {
    let root = SCNNode()
    private var bones: [String: SCNNode] = [:]
    private var joints: [String: SCNNode] = [:]
    private let boneMat: SCNMaterial
    private let jointMat: SCNMaterial
    private let clubShaft: SCNNode
    private let clubHead: SCNNode
    let watch: SCNNode
    let watchPulse: SCNNode
    private let shadow: SCNNode

    // address stance, solved once
    private var stance: (feet: SIMD3<Float>, fwd: SIMD3<Float>, side: SIMD3<Float>)?
    private var lastLeft: [String: SIMD3<Float>]?
    private var lastRight: [String: SIMD3<Float>]?
    private var lastClub: (SIMD3<Float>, SIMD3<Float>)?
    let righty: Bool
    var hideHead = false  // camera is in it (pov): only hands (fingers), club + watch show, like the headset

    static let fingerChains: [[String]] = ["thumb", "indexFinger", "middleFinger", "ringFinger", "littleFinger"].map { f in
        f == "thumb"
            ? ["wrist", "thumbKnuckle", "thumbIntermediateBase", "thumbIntermediateTip", "thumbTip"]
            : ["wrist", f + "Metacarpal", f + "Knuckle", f + "IntermediateBase", f + "IntermediateTip", f + "Tip"]
    }

    init(righty: Bool) {
        self.righty = righty
        boneMat = SCNMaterial()
        boneMat.lightingModel = .constant
        boneMat.diffuse.contents = NSColor(srgbRed: 0.55, green: 0.95, blue: 1.0, alpha: 1)
        boneMat.emission.contents = NSColor(srgbRed: 0.35, green: 0.85, blue: 1.0, alpha: 1)
        jointMat = SCNMaterial()
        jointMat.lightingModel = .constant
        jointMat.diffuse.contents = NSColor.white
        jointMat.emission.contents = NSColor.white

        let shaft = SCNCylinder(radius: 0.006, height: 1)
        let sm = SCNMaterial()
        sm.lightingModel = .physicallyBased
        sm.diffuse.contents = NSColor(white: 0.85, alpha: 1)
        sm.metalness.contents = 0.9
        sm.roughness.contents = 0.25
        shaft.materials = [sm]
        clubShaft = SCNNode(geometry: shaft)
        let head = SCNBox(width: 0.075, height: 0.045, length: 0.025, chamferRadius: 0.008)
        let hm = SCNMaterial()
        hm.lightingModel = .physicallyBased
        hm.diffuse.contents = NSColor(white: 0.7, alpha: 1)
        hm.metalness.contents = 1
        hm.roughness.contents = 0.3
        head.materials = [hm]
        clubHead = SCNNode(geometry: head)

        // the watch on the lead wrist + a ring that pops at impact
        let w = SCNBox(width: 0.045, height: 0.012, length: 0.05, chamferRadius: 0.01)
        let wm = SCNMaterial()
        wm.lightingModel = .constant
        wm.diffuse.contents = NSColor(srgbRed: 1, green: 0.8, blue: 0.25, alpha: 1)
        wm.emission.contents = NSColor(srgbRed: 1, green: 0.75, blue: 0.2, alpha: 1)
        w.materials = [wm]
        watch = SCNNode(geometry: w)
        let ring = SCNTorus(ringRadius: 0.05, pipeRadius: 0.004)
        let rm = SCNMaterial()
        rm.lightingModel = .constant
        rm.diffuse.contents = NSColor(srgbRed: 1, green: 0.8, blue: 0.3, alpha: 1)
        rm.emission.contents = NSColor(srgbRed: 1, green: 0.8, blue: 0.3, alpha: 1)
        rm.transparency = 0
        ring.materials = [rm]
        watchPulse = SCNNode(geometry: ring)

        let disc = SCNCylinder(radius: 0.45, height: 0.001)
        let dm = SCNMaterial()
        dm.lightingModel = .constant
        dm.diffuse.contents = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { r in
            let g = NSGradient(colors: [NSColor(white: 0, alpha: 0.35), NSColor(white: 0, alpha: 0)])
            g?.draw(in: NSBezierPath(ovalIn: r), relativeCenterPosition: .zero)
            return true
        }
        dm.writesToDepthBuffer = false
        disc.materials = [dm, dm, dm]
        shadow = SCNNode(geometry: disc)

        root.addChildNode(shadow)
        root.addChildNode(clubShaft)
        root.addChildNode(clubHead)
        root.addChildNode(watch)
        root.addChildNode(watchPulse)
    }

    private func bone(_ name: String, _ a: SIMD3<Float>?, _ b: SIMD3<Float>?, r: Float = 0.018) {
        let node = bones[name] ?? {
            let n = SCNNode(geometry: SCNCapsule(capRadius: CGFloat(r), height: 1))
            n.geometry!.materials = [boneMat]
            root.addChildNode(n)
            bones[name] = n
            return n
        }()
        guard let a, let b, simd_distance(a, b) > 0.001 else {
            node.isHidden = true
            return
        }
        node.isHidden = false
        let d = b - a
        let len = simd_length(d)
        (node.geometry as! SCNCapsule).height = CGFloat(len + 2 * r)
        node.simdPosition = (a + b) / 2
        node.simdOrientation = simd_quatf(from: [0, 1, 0], to: d / len)
    }

    private func joint(_ name: String, _ p: SIMD3<Float>?, r: Float = 0.028) {
        let node = joints[name] ?? {
            let n = SCNNode(geometry: SCNSphere(radius: CGFloat(r)))
            n.geometry!.materials = [jointMat]
            root.addChildNode(n)
            joints[name] = n
            return n
        }()
        guard let p else {
            node.isHidden = true
            return
        }
        node.isHidden = false
        node.simdPosition = p
    }

    // plane-of-arm 2 bone ik, pole = where the elbow "wants" to be
    static func elbow(shoulder s: SIMD3<Float>, wrist w: SIMD3<Float>, pole: SIMD3<Float>, upper: Float = 0.30, fore: Float = 0.27) -> SIMD3<Float> {
        var d = w - s
        var len = simd_length(d)
        len = min(max(len, 0.05), upper + fore - 0.001)
        d = simd_normalize(d)
        let a = (upper * upper - fore * fore + len * len) / (2 * len)
        let h = sqrt(max(upper * upper - a * a, 0))
        var bend = pole - s
        bend -= simd_dot(bend, d) * d
        let bl = simd_length(bend)
        let bn = bl > 1e-4 ? bend / bl : simd_normalize(simd_cross(d, [0, 1, 0]))
        return s + d * a + bn * h
    }

    func update(_ p: Pose, impactPulse: Float) {
        let left = p.left ?? lastLeft
        let right = p.right ?? lastRight
        if p.left != nil { lastLeft = p.left }
        if p.right != nil { lastRight = p.right }
        guard let head = p.head else { return }
        let up = SIMD3<Float>(0, 1, 0)
        let headFwd = head.q.act([0, 0, -1])

        if stance == nil {
            var f = SIMD3(headFwd.x, 0, headFwd.z)
            f = simd_length(f) > 0.01 ? simd_normalize(f) : [0, 0, -1]
            let side = simd_normalize(simd_cross(f, up))  // golfers right
            let feet = SIMD3(head.p.x, 0, head.p.z) - 0.2 * f
            stance = (feet, f, side)
        }
        let st = stance!

        // upper body
        let neck = head.p + head.q.act([0, -0.13, 0.07])
        let chest = neck - [0, 0.07, 0] + 0.02 * st.fwd
        // turn: where the hands are around the chest
        var turn: Float = 0
        let lw = left?["wrist"]
        let rw = right?["wrist"]
        if let mid = lw.flatMap({ l in rw.map { (l + $0) / 2 } }) ?? lw ?? rw {
            var h = mid - chest
            h.y = 0
            if simd_length(h) > 0.05 {
                let ang = atan2(simd_dot(h, st.side), simd_dot(h, st.fwd))
                turn = min(max(ang, -1.9), 1.9) * 0.8
            }
        }
        let rot = simd_quatf(angle: -turn, axis: up)
        let shAxis = rot.act(st.side)
        let rShoulder = chest + 0.19 * shAxis + 0.02 * st.fwd
        let lShoulder = chest - 0.19 * shAxis + 0.02 * st.fwd

        // lower body. hips turn about half the shoulders
        let pelvis = st.feet + [0, 0.9, 0] - 0.1 * st.fwd
        let hipRot = simd_quatf(angle: -turn * 0.45, axis: up)
        let hipAxis = hipRot.act(st.side)
        let rHip = pelvis + 0.12 * hipAxis
        let lHip = pelvis - 0.12 * hipAxis
        let rFoot = st.feet + 0.24 * st.side
        let lFoot = st.feet - 0.24 * st.side
        let rKnee = (rHip + rFoot) / 2 + 0.07 * st.fwd + 0.01 * st.side
        let lKnee = (lHip + lFoot) / 2 + 0.07 * st.fwd - 0.01 * st.side

        // spine
        bone("spine", pelvis, chest, r: 0.022)
        bone("neck", chest, neck, r: 0.018)
        bone("shoulders", lShoulder, rShoulder, r: 0.02)
        bone("hips", lHip, rHip, r: 0.02)
        bone("lThigh", lHip, lKnee)
        bone("lShin", lKnee, lFoot)
        bone("rThigh", rHip, rKnee)
        bone("rShin", rKnee, rFoot)
        bone("lToe", lFoot, lFoot + 0.12 * st.fwd - 0.03 * st.side, r: 0.014)
        bone("rToe", rFoot, rFoot + 0.12 * st.fwd + 0.03 * st.side, r: 0.014)
        for (n, q) in [("pelvis", pelvis), ("lHip", lHip), ("rHip", rHip), ("lKnee", lKnee), ("rKnee", rKnee),
                       ("lFoot", lFoot), ("rFoot", rFoot), ("chest", chest), ("lSh", lShoulder), ("rSh", rShoulder)] {
            joint(n, q, r: 0.024)
        }
        // head: sphere a bit behind the eyes
        joint("head", hideHead ? nil : head.p + head.q.act([0, -0.02, 0.08]), r: 0.095)
        if hideHead { bone("neck", nil, nil) }

        func arm(_ side: String, _ hand: [String: SIMD3<Float>]?, shoulder: SIMD3<Float>) {
            guard let hand, let w = hand["wrist"] else {
                bone(side + "Upper", nil, nil)
                bone(side + "Fore", nil, nil)
                return
            }
            let fa = hand["forearmArm"] ?? w
            let fw = hand["forearmWrist"] ?? w
            var dir = fa - fw
            dir = simd_length(dir) > 0.01 ? simd_normalize(dir) : simd_normalize(shoulder - w)
            let pole = w + 0.27 * dir + 0.05 * (shoulder - w)
            let e = Golfer.elbow(shoulder: shoulder, wrist: w, pole: pole)
            bone(side + "Upper", shoulder, e)
            bone(side + "Fore", e, w)
            joint(side + "Elbow", e, r: 0.024)
            joint(side + "Wrist", w, r: 0.02)
            for (ci, chain) in Golfer.fingerChains.enumerated() {
                for k in 1..<chain.count {
                    bone("\(side)f\(ci)_\(k)", hand[chain[k - 1]], hand[chain[k]], r: 0.0065)
                }
            }
        }
        arm("l", left, shoulder: lShoulder)
        arm("r", right, shoulder: rShoulder)

        // club
        var club = lastClub
        if let g = p.grip, let c = p.club { club = (g, c) }
        lastClub = club
        if let (g, c) = club {
            let d = c - g
            let len = simd_length(d)
            let dir = d / max(len, 0.001)
            (clubShaft.geometry as! SCNCylinder).height = CGFloat(len)
            clubShaft.simdPosition = (g + c) / 2
            clubShaft.simdOrientation = simd_quatf(from: [0, 1, 0], to: dir)
            clubHead.simdPosition = c + 0.02 * dir
            clubHead.simdOrientation = clubShaft.simdOrientation
            clubShaft.isHidden = false
            clubHead.isHidden = false
        } else {
            clubShaft.isHidden = true
            clubHead.isHidden = true
        }

        // watch on the lead wrist (left for a righty)
        let leadHand = righty ? left : right
        if let h = leadHand, let w = h["wrist"], let fa = h["forearmArm"] {
            let dir = simd_normalize(fa - w)
            watch.simdPosition = w + 0.035 * dir
            watch.simdOrientation = simd_quatf(from: [0, 0, 1], to: dir)
            watch.isHidden = false
            watchPulse.simdPosition = watch.simdPosition
            watchPulse.simdOrientation = simd_quatf(from: [0, 1, 0], to: dir)
            watchPulse.simdScale = SIMD3(repeating: 1 + 5 * impactPulse)
            watchPulse.geometry!.firstMaterial!.transparency = CGFloat(impactPulse > 0 ? (1 - impactPulse) : 0)
        } else {
            watch.isHidden = true
        }

        shadow.simdPosition = st.feet + [0, 0.012, 0] + 0.1 * st.fwd
        shadow.isHidden = hideHead
        if hideHead {
            for (name, n) in bones where !name.hasPrefix("lf") && !name.hasPrefix("rf") { n.isHidden = true }
            for (name, n) in joints where name != "lWrist" && name != "rWrist" { n.isHidden = true }
        }
    }

    var feet: SIMD3<Float>? { stance?.feet }
    var forward: SIMD3<Float>? { stance?.fwd }
    var side: SIMD3<Float>? { stance?.side }
}
