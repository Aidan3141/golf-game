import AppKit
import SceneKit
import simd

// same range as the avp (RangeScene.swift), rebuilt in scenekit. range-local coords under a
// root w/ the recorded world transform, so the golfer data lines up 1:1
enum RangeBuilder {
    static let teePosition = SIMD3<Float>(0, 0, -2.2)
    static let skyYaw: Float = 1.8
    nonisolated(unsafe) static var skySign: Float = 1
    nonisolated(unsafe) static var skyExtra: Float = 2.79  // matched by eye to the headset (sun just right of the target line)
    static let roughTint = NSColor(srgbRed: 0.33, green: 0.70, blue: 0.21, alpha: 1)
    static let stripeLight = NSColor(srgbRed: 0.43, green: 0.84, blue: 0.29, alpha: 1)
    static let stripeDark = NSColor(srgbRed: 0.36, green: 0.75, blue: 0.24, alpha: 1)
    static let greenTint = NSColor(srgbRed: 0.58, green: 0.93, blue: 0.42, alpha: 1)
    static let flagColors: [Int: NSColor] = [
        50: .systemRed, 100: .systemYellow, 150: .systemBlue, 200: .white, 250: .systemOrange,
    ]
    static let flagOffsets: [Int: Float] = [50: -6, 100: 9, 150: -12, 200: 14, 250: -16]
    static let yardsPerMeter: Float = 1.0936133

    static func build(in scene: SCNScene, rec: Recording, assets: URL) -> SCNNode {
        let root = SCNNode()
        root.simdTransform = rec.rootMatrix
        scene.rootNode.addChildNode(root)

        // sky + light. root yaw + the apps sky yaw
        let m = rec.rootMatrix
        let rootYaw = atan2(-m.columns.0.z, m.columns.0.x)
        let yaw = (rootYaw + skyYaw) * skySign + skyExtra
        scene.background.contents = NSImage(contentsOf: assets.appending(path: "range_sky.jpg"))
        scene.background.contentsTransform = SCNMatrix4MakeRotation(CGFloat(-yaw), 0, 1, 0)
        scene.lightingEnvironment.contents = assets.appending(path: "range_ibl.hdr")
        scene.lightingEnvironment.contentsTransform = SCNMatrix4MakeRotation(CGFloat(-yaw), 0, 1, 0)
        scene.lightingEnvironment.intensity = 1.0
        // haze so the far grass melts into the horizon like the headset
        scene.fogStartDistance = 150
        scene.fogEndDistance = 1400
        scene.fogDensityExponent = 1.6
        scene.fogColor = NSColor(srgbRed: 0.62, green: 0.66, blue: 0.62, alpha: 1)

        // warm low sun for shadows, roughly where the sky's sun is
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light!.type = .directional
        sun.light!.intensity = 500
        sun.light!.color = NSColor(srgbRed: 1, green: 0.88, blue: 0.72, alpha: 1)
        sun.light!.castsShadow = true
        sun.light!.shadowMode = .deferred
        sun.light!.shadowColor = NSColor(white: 0, alpha: 0.45)
        sun.light!.shadowRadius = 3
        sun.light!.shadowSampleCount = 8
        sun.light!.orthographicScale = 6
        sun.light!.shadowMapSize = CGSize(width: 4096, height: 4096)
        sun.light!.automaticallyAdjustsShadowProjection = true
        sun.simdPosition = [0, 10, 0]
        sun.simdLook(at: [0, 0, 0] + SIMD3(-6, -4, -3), up: [0, 1, 0], localFront: [0, 0, -1])
        scene.rootNode.addChildNode(sun)

        let grass = NSImage(contentsOf: assets.appending(path: "grass_vivid.jpg"))
        func grassMat(_ tint: NSColor, size: SIMD2<Float>, tile: Float = 4) -> SCNMaterial {
            let mat = SCNMaterial()
            mat.lightingModel = .physicallyBased
            mat.diffuse.contents = grass
            mat.multiply.contents = tint.blended(withFraction: 0.18, of: NSColor(white: 0.5, alpha: 1))
            mat.diffuse.wrapS = .repeat
            mat.diffuse.wrapT = .repeat
            mat.diffuse.contentsTransform = SCNMatrix4MakeScale(CGFloat(size.x / tile), CGFloat(size.y / tile), 1)
            mat.diffuse.mipFilter = .linear
            mat.diffuse.maxAnisotropy = 16
            mat.roughness.contents = 0.95
            return mat
        }

        // ground
        let g = SCNPlane(width: 3000, height: 3000)
        g.materials = [grassMat(roughTint, size: [3000, 3000])]
        let ground = SCNNode(geometry: g)
        ground.eulerAngles.x = -.pi / 2
        ground.simdPosition = teePosition
        root.addChildNode(ground)

        // fairway stripes
        let stripeW: Float = 9
        let length: Float = 330
        for i in -4..<4 {
            let p = SCNPlane(width: CGFloat(stripeW), height: CGFloat(length))
            p.materials = [grassMat(i.isMultiple(of: 2) ? stripeLight : stripeDark, size: [stripeW, length])]
            let n = SCNNode(geometry: p)
            n.eulerAngles.x = -.pi / 2
            n.simdPosition = [(Float(i) + 0.5) * stripeW, 0.002, -length / 2 - 2]
            root.addChildNode(n)
        }

        // tee box mat
        let box = SCNBox(width: 1.6, height: 0.01, length: 1.6, chamferRadius: 0.004)
        let bm = SCNMaterial()
        bm.lightingModel = .physicallyBased
        bm.diffuse.contents = NSColor(srgbRed: 0.18, green: 0.32, blue: 0.16, alpha: 1)
        bm.roughness.contents = 0.9
        box.materials = [bm]
        let tee = SCNNode(geometry: box)
        tee.simdPosition = teePosition
        root.addChildNode(tee)

        for yd in [50, 100, 150, 200, 250] { addFlag(yd, to: root) }
        return root
    }

    static func addFlag(_ yards: Int, to root: SCNNode) {
        let z = -Float(yards) / yardsPerMeter
        let flag = SCNNode()
        flag.simdPosition = teePosition + [flagOffsets[yards] ?? 0, 0, z]

        let green = SCNCylinder(radius: 9, height: 0.02)
        let gm = SCNMaterial()
        gm.lightingModel = .physicallyBased
        gm.diffuse.contents = greenTint
        gm.roughness.contents = 0.7
        green.materials = [gm]
        let gn = SCNNode(geometry: green)
        gn.simdPosition.y = 0.01
        flag.addChildNode(gn)

        let s = max(1, Float(yards) / 80)
        let pole = SCNCylinder(radius: CGFloat(0.03 * s), height: CGFloat(3 * s))
        pole.materials = [plain(.white)]
        let pn = SCNNode(geometry: pole)
        pn.simdPosition.y = 1.5 * s
        flag.addChildNode(pn)

        let color = flagColors[yards] ?? .white
        let cloth = SCNBox(width: CGFloat(0.9 * s), height: CGFloat(0.6 * s), length: 0.01, chamferRadius: 0)
        cloth.materials = [plain(color)]
        let cn = SCNNode(geometry: cloth)
        cn.simdPosition = [0.45 * s, 2.7 * s, 0]
        flag.addChildNode(cn)

        let sign = Sign.node(value: "\(yards)", unit: "yd", caption: nil, accent: color, height: 1.1 * s)
        sign.simdPosition.y = 3.9 * s
        flag.addChildNode(sign)
        root.addChildNode(flag)
    }

    static func plain(_ c: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = c
        m.roughness.contents = 0.6
        return m
    }
}

// the apps sign style, drawn to a texture: dark plate, accent bar, big white number, small unit
enum Sign {
    static func image(value: String, unit: String?, caption: String?, accent: NSColor) -> (NSImage, CGFloat) {
        let numFont = NSFont(name: "DINAlternate-Bold", size: 200) ?? .systemFont(ofSize: 200, weight: .heavy)
        let unitFont = NSFont(name: "Galvji-Bold", size: 80) ?? .systemFont(ofSize: 80, weight: .bold)
        let capFont = NSFont(name: "Galvji-Bold", size: 64) ?? .systemFont(ofSize: 64, weight: .heavy)
        let num = NSAttributedString(string: value, attributes: [.font: numFont, .foregroundColor: NSColor.white])
        let un = unit.map { NSAttributedString(string: $0, attributes: [.font: unitFont, .foregroundColor: NSColor(white: 0.85, alpha: 1)]) }
        let cap = caption.map { NSAttributedString(string: $0, attributes: [.font: capFont, .foregroundColor: accent]) }
        let ns = num.size()
        let us = un?.size() ?? .zero
        let cs = cap?.size() ?? .zero
        let pad: CGFloat = 50
        let bar: CGFloat = 20
        let gap: CGFloat = 30
        let textW = max(ns.width + (un == nil ? 0 : 20 + us.width), cs.width)
        let capH: CGFloat = cap == nil ? 0 : cs.height - 10
        let w = 28 + bar + gap + textW + pad
        let numH = numFont.capHeight
        let h = pad * 2 + numH + capH
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let plate = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h), xRadius: min(60, h / 2), yRadius: min(60, h / 2))
            NSColor(white: 0.05, alpha: 0.62).setFill()
            plate.fill()
            accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: 28, y: pad * 0.6, width: bar, height: h - pad * 1.2), xRadius: bar / 2, yRadius: bar / 2).fill()
            let x0 = 28 + bar + gap
            num.draw(at: NSPoint(x: x0, y: pad + numFont.descender))
            un?.draw(at: NSPoint(x: x0 + ns.width + 20, y: pad + unitFont.descender))
            cap?.draw(at: NSPoint(x: x0, y: pad + numH + 4 + capFont.descender))
            _ = cs
            return true
        }
        return (img, h / numH)
    }

    // height = number height in meters, like the app
    static func node(value: String, unit: String?, caption: String?, accent: NSColor, height: Float) -> SCNNode {
        let (img, ratio) = image(value: value, unit: unit, caption: caption, accent: accent)
        let hm = CGFloat(height) * ratio
        let plane = SCNPlane(width: hm * img.size.width / img.size.height, height: hm)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = img
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        plane.materials = [m]
        let n = SCNNode(geometry: plane)
        let c = SCNBillboardConstraint()
        c.freeAxes = .Y
        n.constraints = [c]
        n.renderingOrder = 10
        return n
    }
}
