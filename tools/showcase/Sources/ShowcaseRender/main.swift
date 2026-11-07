import AppKit
import Foundation
import Metal
import SceneKit
import simd

// ShowcaseRender --rec shot.json --assets Apps/VisionOS/Resources --out third.mp4 [--fps 60] [--stills dir]
// renders the 3rd person part of the showcase: swing, impact slow mo, ball flight, side view

var args: [String: String] = [:]
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    if a.hasPrefix("--") { args[String(a.dropFirst(2))] = it.next() ?? "" }
}
guard let recPath = args["rec"], let assetsPath = args["assets"] else {
    print("usage: ShowcaseRender --rec shot.json --assets dir --out out.mp4 [--fps 60] [--stills dir]")
    exit(1)
}
let fps = Double(args["fps"] ?? "60") ?? 60
let W = Int(args["w"] ?? "1920") ?? 1920
let H = Int(args["h"] ?? "1080") ?? 1080
let rec = try Recording.load(recPath)
if let s = args["skySign"], let v = Float(s) { RangeBuilder.skySign = v }
if let s = args["skyExtra"], let v = Float(s) { RangeBuilder.skyExtra = v }
let assets = URL(fileURLWithPath: assetsPath)
// launch = first frame the ball actually moves (near the recorded mark). a test swing in the app
// animates the club first so the mark can be early, + the ball would sit there after the hit
let L: Double = {
    guard let b0 = rec.frames.first(where: { $0.t >= rec.launchT - 0.05 })?.ball else { return rec.launchT }
    let rest = SIMD3(b0[0], b0[1], b0[2])
    let moved = rec.frames.first { f in
        guard f.t >= rec.launchT - 0.05, let b = f.ball else { return false }
        return simd_distance(SIMD3(b[0], b[1], b[2]), rest) > 0.01
    }
    guard let m = moved, m.t - rec.launchT < 3 else { return rec.launchT }
    return m.t - 0.011
}()
let flight = rec.shot.flightSecs

// MARK: scene

let scene = SCNScene()
let rangeRoot = RangeBuilder.build(in: scene, rec: rec, assets: assets)
let golfer = Golfer(righty: rec.isRighty)
scene.rootNode.addChildNode(golfer.root)

let ballNode: SCNNode = {
    let s = SCNSphere(radius: 0.0214)
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = NSColor.white
    m.emission.contents = NSColor.white
    s.materials = [m]
    let n = SCNNode(geometry: s)
    scene.rootNode.addChildNode(n)
    return n
}()

// tracer: pool of glowing segments
let tracerMat: SCNMaterial = {
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = NSColor(srgbRed: 1, green: 0.86, blue: 0.35, alpha: 1)
    return m
}()
var tracer: [SCNNode] = []

// ball samples after launch (from the recording)
let ballPath: [(t: Double, p: SIMD3<Float>)] = rec.frames.compactMap { f in
    guard f.t >= L - 0.02, let b = f.ball else { return nil }
    return (f.t - L, SIMD3(b[0], b[1], b[2]))
}
let groundY = rec.tee[1]
let peakIdx = ballPath.indices.max { ballPath[$0].p.y < ballPath[$1].p.y } ?? 0
let landIdx = ballPath.indices.first { $0 > peakIdx && ballPath[$0].p.y < groundY + 0.08 } ?? ballPath.count - 1
let landing = ballPath[landIdx]
let rest = ballPath.last!
let teeW = SIMD3(rec.tee[0], rec.tee[1], rec.tee[2])
let targetDir: SIMD3<Float> = {
    let m = rec.rootMatrix
    let d = SIMD3(-m.columns.2.x, 0, -m.columns.2.z)
    return simd_normalize(d)
}()

let carrySign = Sign.node(value: String(format: "%.0f", rec.shot.carryYd), unit: "yd", caption: "carry", accent: .systemYellow, height: 3.2)
carrySign.simdPosition = landing.p + [0, 5, 0]
scene.rootNode.addChildNode(carrySign)
let totalSign = Sign.node(value: String(format: "%.0f", rec.shot.totalYd), unit: "yd", caption: "total", accent: .white, height: 3.2)
totalSign.simdPosition = rest.p + [0, 5, 0]
scene.rootNode.addChildNode(totalSign)

func updateTracer(upTo s: Double, camPos: SIMD3<Float>) {
    let pts = ballPath.filter { $0.t <= s }.enumerated().filter { $0.offset % 3 == 0 }.map(\.element.p)
    var pts2 = pts
    if let last = ballPath.last(where: { $0.t <= s }) { pts2.append(last.p) }
    let n = max(pts2.count - 1, 0)
    while tracer.count < n {
        let c = SCNNode(geometry: SCNCylinder(radius: 1, height: 1))
        c.geometry!.materials = [tracerMat]
        scene.rootNode.addChildNode(c)
        tracer.append(c)
    }
    for (i, node) in tracer.enumerated() {
        guard i < n else {
            node.isHidden = true
            continue
        }
        let a = pts2[i]
        let b = pts2[i + 1]
        let d = b - a
        let len = simd_length(d)
        guard len > 0.001 else {
            node.isHidden = true
            continue
        }
        node.isHidden = false
        let r = max(0.0035, 0.00065 * simd_distance(camPos, (a + b) / 2))
        node.simdScale = [r, len, r]
        node.simdPosition = (a + b) / 2
        node.simdOrientation = simd_quatf(from: [0, 1, 0], to: d / len)
    }
}

// MARK: camera

let camNode = SCNNode()
let cam = SCNCamera()
cam.zNear = 0.05
cam.zFar = 4000
cam.wantsHDR = true
cam.bloomIntensity = 0.18
cam.bloomThreshold = 0.95
cam.bloomBlurRadius = 6
cam.wantsExposureAdaptation = false
cam.exposureOffset = 0
cam.vignettingIntensity = 0.35
cam.vignettingPower = 0.6
camNode.camera = cam
scene.rootNode.addChildNode(camNode)

func look(_ eye: SIMD3<Float>, _ at: SIMD3<Float>, fov: Float) {
    camNode.simdPosition = eye
    camNode.simdLook(at: at, up: [0, 1, 0], localFront: [0, 0, -1])
    cam.fieldOfView = CGFloat(fov)
}

func ease(_ x: Double) -> Float {
    let c = min(max(x, 0), 1)
    return Float(c * c * (3 - 2 * c))
}

// MARK: edit

struct Segment {
    var name: String
    var caption: String
    var from: Double  // data time
    var to: Double
    var speed: Double  // data secs per video sec
    var extraHold: Double = 0  // freeze on the last data frame this long
    var duration: Double { (to - from) / speed + extraHold }
}

var segments = [
    Segment(name: "pov", caption: "what i see in the headset", from: L - 1.7, to: L + 3.2, speed: 1),
    Segment(name: "swing", caption: "same swing from the outside, rebuilt from head + hand tracking", from: L - 2.1, to: L + 0.7, speed: 1),
    Segment(name: "impact", caption: "impact, 5x slower", from: L - 0.4, to: L + 0.12, speed: 0.2),
    Segment(name: "flight", caption: "ball flight", from: L, to: L + min(flight, 9), speed: 1),
    Segment(name: "side", caption: "the shot", from: L + min(flight, 9), to: L + min(flight, 9), speed: 1, extraHold: 3.2),
]

// golfer frame for the cameras (from the address pose)
golfer.update(rec.pose(at: L - 2.2), impactPulse: 0)
let feet = golfer.feet ?? teeW
let fwd = golfer.forward ?? [0, 0, -1]
let side = golfer.side ?? [1, 0, 0]
let chestAt = feet + [0, 1.0, 0] + 0.15 * fwd

func camera(for seg: Segment, x: Double, s: Double) {
    switch seg.name {
    case "swing":
        // face on, slow orbit toward the target side
        let a = Float(-0.15 - 0.45 * Double(ease(x)))
        let toCam = simd_quatf(angle: a, axis: [0, 1, 0]).act(fwd)
        look(chestAt + 4.6 * toCam + [0, 0.05, 0], chestAt - [0, 0.32, 0], fov: 40)
    case "impact":
        // low down the line, behind the ball looking at the hands, slow push
        // down the line: behind, on the line thru the ball + hands, golfer on the right
        let mid = (teeW + feet) / 2
        let eye = mid - (5.2 - 0.8 * ease(x)) * targetDir + [0, 1.3, 0]
        look(eye, mid + [0, 0.78, 0], fov: 36)
    case "flight":
        // way behind the golfer down the line, camera stays put, turns + zooms to keep the ball
        let b = ballPath.last(where: { $0.t <= s })?.p ?? teeW
        let k = ease(x * 1.4)
        let eye = teeW - 9 * targetDir - 3.0 * fwd + [0, 2.0 + 1.5 * k, 0]
        let focus = simd_mix(teeW + 40 * targetDir + [0, 8, 0], b, SIMD3(repeating: min(1, 0.35 + Float(s) * 1.2)))
        let dist = simd_distance(eye, focus)
        let fov = min(50, max(16, 2 * atan(26 / dist) * 180 / .pi))
        look(eye, focus, fov: fov)
    default:
        // side on, whole flight in frame
        let mid = (teeW + rest.p) / 2
        let perp = simd_normalize(simd_cross([0, 1, 0], targetDir))
        let dist = simd_distance(teeW, rest.p)
        let apex = ballPath.map(\.p.y).max() ?? 20
        let eye = mid + perp * dist * (0.78 - 0.04 * ease(x)) + [0, apex * 0.25 + 2, 0]
        look(eye, mid + [0, apex * 0.5, 0], fov: 50)
    }
}

// MARK: overlays

let watchT: [(t: Double, angle: Double)] = rec.frames.compactMap { f in f.watch.map { (f.t, $0) } }
func wristSpeed(at t: Double) -> Double {
    guard let i = watchT.firstIndex(where: { $0.t >= t }), i > 2 else { return 0 }
    let a = watchT[i - 3]
    let b = watchT[i]
    return min(abs(b.angle - a.angle) / max(b.t - a.t, 1e-3), rec.shot.wristSpeed)  // club angle rate, never over the watch's peak
}
let peakWrist = rec.shot.wristSpeed

func phaseName(_ p: String) -> String {
    switch p {
    case "backswing": return "backswing"
    case "top": return "top"
    case "downswing": return "downswing"
    case "impact": return "impact"
    case "followThrough": return "follow through"
    case "address": return "address"
    default: return "set up"
    }
}

let overlay = Overlay(width: W, height: H, rec: rec)
if args["card"] != nil { segments = [] }

// sound cues for the mix (video secs)
var cues: [[String: Double]] = []
var vt = 0.0
for seg in segments {
    func at(_ dataT: Double) -> Double? {
        guard dataT >= seg.from, dataT <= seg.to else { return nil }
        return vt + (dataT - seg.from) / seg.speed
    }
    if seg.name != "flight", let t = at(L) { cues.append(["t": t, "impact": 1, "rate": seg.speed]) }  // flight starts on impact, already heard it
    if seg.name == "flight" || seg.name == "pov", let t = at(L + landing.t) { cues.append(["t": t, "land": 1, "rate": 1]) }
    vt += seg.duration
}
if let p = args["cues"] {
    try JSONSerialization.data(withJSONObject: cues).write(to: URL(fileURLWithPath: p))
}

// MARK: render

guard let device = MTLCreateSystemDefaultDevice() else { fatalError("no metal") }
let renderer = SCNRenderer(device: device, options: nil)
renderer.scene = scene
renderer.pointOfView = camNode
renderer.autoenablesDefaultLighting = false

let stillsDir = args["stills"]
var encoder: FFmpegPipe?
if stillsDir == nil {
    encoder = try FFmpegPipe(out: args["out"] ?? "third.mp4", width: W, height: H, fps: fps)
}
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!

var videoT = 0.0
let stillTimes: [Double] = (args["stillAt"] ?? "").split(separator: ",").compactMap { Double($0) }
let total = segments.map(\.duration).reduce(0, +)
var frameNo = 0
let startClock = Date()
for seg in segments {
    let n = Int((seg.duration * fps).rounded())
    for k in 0..<n {
        let local = Double(k) / fps
        let x = local / seg.duration
        let s = min(seg.from + local * seg.speed, seg.to)  // data time
        defer { videoT += 1 / fps; frameNo += 1 }
        if stillsDir != nil {
            // only render the asked for video times (or 1 per segment)
            let wanted = stillTimes.isEmpty ? (k == n / 2) : stillTimes.contains { abs($0 - videoT) < 0.5 / fps }
            if !wanted { continue }
        }
        let pose = rec.pose(at: s)
        let pulseT = s - L
        golfer.hideHead = seg.name == "pov"
        // pov: hands drop out of view once the swing starts (they swung thru the camera)
        golfer.hideHands = seg.name == "pov" && s > L - rec.shot.backswing - rec.shot.downswing
        golfer.hideClub = seg.name == "pov" && s > L + 0.12
        golfer.update(pose, impactPulse: pulseT >= 0 && pulseT < 0.35 ? Float(pulseT / 0.35) : 0)
        // ball
        let bp: SIMD3<Float> = s < L ? (pose.ball ?? teeW) : (ballPath.last(where: { $0.t <= s - L })?.p ?? teeW)
        if seg.name == "pov", let h = pose.head {
            camNode.simdPosition = h.p
            camNode.simdOrientation = h.q
            cam.fieldOfView = 66
        } else {
            camera(for: seg, x: x, s: s - L)
        }
        ballNode.simdPosition = bp
        ballNode.simdScale = .one  // real size the whole way, no growing w/ distance
        updateTracer(upTo: s - L, camPos: camNode.simdPosition)
        carrySign.isHidden = s - L < landing.t
        totalSign.isHidden = s - L < rest.t - 0.2 || seg.name != "side" && seg.name != "flight"
        if seg.name == "swing" || seg.name == "impact" || (seg.name == "pov" && s - L < landing.t) {
            carrySign.isHidden = true
            totalSign.isHidden = true
        }

        let img = renderer.snapshot(atTime: videoT, with: CGSize(width: W, height: H), antialiasingMode: .multisampling4X)
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))

        // overlay state
        var st = Overlay.State()
        st.caption = seg.caption
        st.segment = seg.name
        st.segX = x
        st.dataT = s
        st.phase = phaseName(pose.phase)
        st.wristSpeed = s < L + 0.3 ? wristSpeed(at: s) : 0
        st.impact = pulseT >= 0 && pulseT < 0.6 ? pulseT / 0.6 : nil
        st.ballT = s - L
        if s >= L {
            let downrange = simd_dot(bp - teeW, targetDir) * RangeBuilder.yardsPerMeter
            st.ballYards = Double(max(downrange, 0))
            st.ballHeightFt = Double(max(bp.y - groundY, 0)) * 3.28084
        }
        overlay.draw(in: ctx, st)

        if let dir = stillsDir {
            let out = ctx.makeImage()!
            let url = URL(fileURLWithPath: dir).appending(path: String(format: "still_%@_%05.2f.png", seg.name, videoT))
            let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, out, nil)
            CGImageDestinationFinalize(dest)
            print("wrote", url.lastPathComponent)
        } else {
            try encoder!.write(ctx)
            if frameNo % 60 == 0 {
                print(String(format: "%.1f / %.1f s  (%.0fs elapsed)", videoT, total, Date().timeIntervalSince(startClock)))
            }
        }
    }
}
// title / end card: slow drift over the empty range at sunset + big text
if let card = args["card"] {
    golfer.root.isHidden = true
    ballNode.isHidden = true
    carrySign.isHidden = true
    totalSign.isHidden = true
    let secs = Double(args["seconds"] ?? "3") ?? 3
    let n = Int(secs * fps)
    for k in 0..<n {
        let x = Double(k) / Double(n)
        let base = teeW - 6 * targetDir + [0, 1.7, 0] - 2 * fwd
        let eye = base + Float(x) * 2.5 * targetDir + [0, Float(x) * 0.6, 0]
        look(eye, teeW + 120 * targetDir + [0, 14 + 4 * Float(x), 0] + 25 * side, fov: 55)
        let img = renderer.snapshot(atTime: Double(k) / fps, with: CGSize(width: W, height: H), antialiasingMode: .multisampling4X)
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
        overlay.card(in: ctx, kind: card, x: x, secs: secs)
        if let dir = stillsDir {
            if k == n / 2 {
                let url = URL(fileURLWithPath: dir).appending(path: "card_\(card).png")
                let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
                CGImageDestinationFinalize(dest)
            }
        } else {
            try encoder!.write(ctx)
        }
    }
}
try encoder?.finish()
print("done", String(format: "%.1fs video", total))
