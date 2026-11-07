import CoreGraphics
import Foundation
import ImageIO
import Metal
import RealityKit
import SwingKit
import UIKit

// builds the driving range. all sizes in meters, downrange = -z
@MainActor
final class RangeScene {
    nonisolated static let teePosition = SIMD3<Float>(0, 0, -2.2)  // far enough out that the backswing misses ur head
    nonisolated static let ballRadius = Float(FlightTuning.standard.ballRadius)
    nonisolated static let groundY: Float = 0.005  // tee box top, ball sits here

    let root = Entity()
    let ball: ModelEntity
    let effects = Entity()  // trails + markers, cleared each shot
    let club = ClubRig()
    private(set) var trainer: TempoTrainer!
    private let iblRoot = Entity()

    init() async {
        ball = ModelEntity(
            mesh: .generateSphere(radius: Self.ballRadius),
            materials: [SimpleMaterial(color: .white, roughness: 0.35, isMetallic: false)]
        )
        ball.components.set(GroundingShadowComponent(castsShadow: true))
        resetBall()

        root.addChild(iblRoot)
        root.addChild(effects)
        root.addChild(ball)
        root.addChild(club.root)

        trainer = TempoTrainer(parent: root)
        await GameAudio.shared.load()
        addAmbience()
        await addSky()
        let grass = await loadGrass()
        addGround(grass)
        addFairway(grass)
        addTeeBox()
        for yd in [50, 100, 150, 200, 250] {
            addFlag(yards: yd)
        }
        applyLighting(to: root)
    }

    nonisolated static var ballRestPosition: SIMD3<Float> {
        teePosition + [0, groundY + ballRadius, 0]
    }

    // first person: turn + slide the world so the golfer spot (club pivot) is where u stand,
    // ball in front of u + target off to ur lead side. behind: original layout
    func applyView(_ mode: AppModel.ViewMode, hand: Handedness) {
        club.setUp(for: hand)
        switch mode {
        case .behind:
            root.orientation = simd_quatf(angle: 0, axis: [0, 1, 0])
            root.position = .zero
        case .firstPerson:
            let t = club.firstPersonTransform(hand: hand)
            root.orientation = t.orientation
            root.position = t.position
        }
    }

    func resetBall() {
        ball.components.remove(BallFlightComponent.self)
        ball.position = Self.ballRestPosition
        ball.scale = .one
    }

    // swingkit coords (x right, y up, z downrange) -> scene
    nonisolated static func scenePoint(_ p: SIMD3<Double>) -> SIMD3<Float> {
        teePosition + SIMD3(Float(p.x), Float(p.y) + groundY + ballRadius, -Float(p.z))
    }

    func clearEffects() {
        effects.children.removeAll()
    }

    // wind + birds all around u
    private func addAmbience() {
        guard let a = GameAudio.shared.ambience else { return }
        let e = Entity()
        e.components.set(AmbientAudioComponent(gain: -14))
        root.addChild(e)
        e.playAudio(a)
    }

    // MARK: sky + lighting

    // kloppenheim 06 pure sky (poly haven, cc0): golden hour, no ground in it so our flat grass
    // runs to the horizon + nothing floats. yaw puts the low sun just right of the target line
    static let skyYaw: Float = 1.8
    static let iblExposure: Float = 0.85

    private func addSky() async {
        // visible backdrop: big inside-out sphere w/ the 8k jpg
        if let url = Bundle.main.url(forResource: "range_sky", withExtension: "jpg"),
           let tex = try? await TextureResource(contentsOf: url, options: .init(semantic: .color)) {
            var mat = UnlitMaterial()
            mat.color = .init(tint: .white, texture: .init(tex))
            let sky = ModelEntity(mesh: .generateSphere(radius: 1900), materials: [mat])
            sky.scale = [-1, 1, 1]  // flip so we see the inside
            sky.orientation = simd_quatf(angle: Self.skyYaw, axis: [0, 1, 0])
            root.addChild(sky)
        }

        // lighting: image based light from the 2k hdr, same yaw so the sun matches the photo
        if let url = Bundle.main.url(forResource: "range_ibl", withExtension: "hdr"),
           let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
           let env = try? await EnvironmentResource(equirectangular: image, options: .init()) {
            iblRoot.components.set(ImageBasedLightComponent(source: .single(env), intensityExponent: Self.iblExposure))
            iblRoot.orientation = simd_quatf(angle: Self.skyYaw, axis: [0, 1, 0])
        }
    }

    private func applyLighting(to entity: Entity) {
        if entity is ModelEntity {
            entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: iblRoot))
        }
        for child in entity.children {
            applyLighting(to: child)
        }
    }

    // MARK: ground

    private struct Grass {
        var color: TextureResource?
        var normal: TextureResource?
        var roughness: TextureResource?
    }

    private func loadGrass() async -> Grass {
        func load(_ name: String, _ semantic: TextureResource.Semantic) async -> TextureResource? {
            guard let url = Bundle.main.url(forResource: name, withExtension: "jpg") else { return nil }
            return try? await TextureResource(contentsOf: url, options: .init(semantic: semantic))
        }
        return Grass(
            color: await load("grass_vivid", .color),  // grass_diff made gray + bright so the tint is the real color
            normal: await load("grass_nor", .normal),
            roughness: await load("grass_rough", .raw)
        )
    }

    // texture is neutral bright gray (grass_vivid) so the tint is pretty much the color u see. tile = meters per texture repeat
    private func grassMaterial(_ grass: Grass, tint: UIColor, size: SIMD2<Float>, tile: Float = 4) -> PhysicallyBasedMaterial {
        let sampler = MaterialParameters.Texture.Sampler(Self.repeatSampler)
        var mat = PhysicallyBasedMaterial()
        if let c = grass.color {
            mat.baseColor = .init(tint: tint, texture: .init(c, sampler: sampler))
        } else {
            mat.baseColor = .init(tint: tint)
        }
        if let n = grass.normal {
            mat.normal = .init(texture: .init(n, sampler: sampler))
        }
        if let r = grass.roughness {
            mat.roughness = .init(texture: .init(r, sampler: sampler))
        }
        mat.metallic = 0.0
        mat.textureCoordinateTransform = .init(scale: size / tile)
        return mat
    }

    private static var repeatSampler: MTLSamplerDescriptor {
        let d = MTLSamplerDescriptor()
        d.sAddressMode = .repeat
        d.tAddressMode = .repeat
        d.minFilter = .linear
        d.magFilter = .linear
        d.mipFilter = .linear
        d.maxAnisotropy = 16  // keeps far grass from turning to mush
        return d
    }

    // flat grass all the way out. opaque to 300m, then rings fade it out by 1500m so the far
    // grass melts into the skys hazy lower half instead of ending in a hard line
    static let groundSolid: Float = 300
    static let groundFadeEnd: Float = 1500
    static let roughTint = UIColor(red: 0.33, green: 0.70, blue: 0.21, alpha: 1)  // vivid, close to the target greens

    private func addGround(_ grass: Grass) {
        let tile: Float = 6
        let center = Self.teePosition
        let solid = ModelEntity(
            mesh: (try? Self.ringMesh(inner: 0, outer: Self.groundSolid, segments: 128, tile: tile)) ?? .generatePlane(width: 600, depth: 600),
            materials: [groundMaterial(grass, tint: Self.roughTint, tile: tile)]
        )
        solid.position = center + [0, -0.01, 0]
        root.addChild(solid)

        let rings = 12
        let step = (Self.groundFadeEnd - Self.groundSolid) / Float(rings)
        for i in 0..<rings {
            let inner = Self.groundSolid + Float(i) * step
            guard let mesh = try? Self.ringMesh(inner: inner, outer: inner + step, segments: 128, tile: tile) else { continue }
            var mat = groundMaterial(grass, tint: Self.roughTint, tile: tile)
            let fade = 1 - (Float(i) + 0.5) / Float(rings)
            mat.blending = .transparent(opacity: .init(floatLiteral: fade * fade * (3 - 2 * fade)))
            let ring = ModelEntity(mesh: mesh, materials: [mat])
            ring.position = center + [0, -0.01, 0]
            root.addChild(ring)
        }
    }

    // uvs are already in tiles (ringMesh), so no extra texture scaling
    private func groundMaterial(_ grass: Grass, tint: UIColor, tile: Float) -> PhysicallyBasedMaterial {
        var m = grassMaterial(grass, tint: tint, size: [tile, tile], tile: tile)
        m.specular = 0.2
        return m
    }

    // mowed stripes down the target line, sit just above the rough
    private func addFairway(_ grass: Grass) {
        let stripeWidth: Float = 9
        let length: Float = 330
        let light = UIColor(red: 0.43, green: 0.84, blue: 0.29, alpha: 1)
        let dark = UIColor(red: 0.36, green: 0.75, blue: 0.24, alpha: 1)
        for i in -4..<4 {
            let stripe = ModelEntity(
                mesh: .generatePlane(width: stripeWidth, depth: length),
                materials: [grassMaterial(grass, tint: i.isMultiple(of: 2) ? light : dark, size: [stripeWidth, length])]
            )
            stripe.position = [(Float(i) + 0.5) * stripeWidth, 0.002, -length / 2 - 2]
            root.addChild(stripe)
        }
    }

    // flat ring (or disc if inner = 0) facing up, uvs in tiles so the grass repeats every `tile` m
    static func ringMesh(inner: Float, outer: Float, segments: Int = 96, tile: Float) throws -> MeshResource {
        var pos: [SIMD3<Float>] = []
        var uv: [SIMD2<Float>] = []
        var idx: [UInt32] = []
        for i in 0...segments {
            let a = Float(i) / Float(segments) * 2 * .pi
            for r in [inner, outer] {
                let p = SIMD3<Float>(cos(a) * r, 0, sin(a) * r)
                pos.append(p)
                uv.append(SIMD2(p.x, p.z) / tile)
            }
        }
        for i in 0..<segments {
            let a = UInt32(i * 2)
            // ccw seen from above so the face points up
            idx += [a, a + 2, a + 1, a + 1, a + 2, a + 3]
        }
        var d = MeshDescriptor(name: "ring")
        d.positions = MeshBuffers.Positions(pos)
        d.normals = MeshBuffers.Normals(Array(repeating: SIMD3<Float>(0, 1, 0), count: pos.count))
        d.textureCoordinates = MeshBuffers.TextureCoordinates(uv)
        // u runs along +x, v along +z -> constant tangents, so the grass normal map works
        d.tangents = MeshBuffers.Tangents(Array(repeating: SIMD3<Float>(1, 0, 0), count: pos.count))
        d.bitangents = MeshBuffers.Tangents(Array(repeating: SIMD3<Float>(0, 0, 1), count: pos.count))
        d.primitives = .triangles(idx)
        return try MeshResource.generate(from: [d])
    }

    private func addTeeBox() {
        var mat = PhysicallyBasedMaterial()
        mat.baseColor = .init(tint: UIColor(red: 0.18, green: 0.32, blue: 0.16, alpha: 1))
        mat.roughness = 0.9
        let mat2 = ModelEntity(mesh: .generateBox(width: 1.6, height: 0.01, depth: 1.6, cornerRadius: 0.004), materials: [mat])
        mat2.position = Self.teePosition + [0, 0, 0]
        root.addChild(mat2)
    }

    // MARK: flags

    private static let flagColors: [Int: UIColor] = [
        50: .systemRed, 100: .systemYellow, 150: .systemBlue, 200: .white, 250: .systemOrange,
    ]
    // staggered l/r like a real range so they dont hide behind each other
    private static let flagOffsets: [Int: Float] = [50: -6, 100: 9, 150: -12, 200: 14, 250: -16]

    private func addFlag(yards: Int) {
        let z = -Float(Units.meters(yards: Double(yards)))
        let flag = Entity()
        flag.position = Self.teePosition + [Self.flagOffsets[yards] ?? 0, 0, z]

        // little target green around the pin
        var greenMat = PhysicallyBasedMaterial()
        greenMat.baseColor = .init(tint: UIColor(red: 0.58, green: 0.93, blue: 0.42, alpha: 1))  // a shade lighter than the fairway
        greenMat.roughness = 0.7
        let green = ModelEntity(mesh: .generateCylinder(height: 0.02, radius: 9), materials: [greenMat])
        green.position.y = 0.01
        flag.addChild(green)

        // poles get bigger far out so u can actually see them
        let s = max(1, Float(yards) / 80)
        let pole = ModelEntity(
            mesh: .generateCylinder(height: 3 * s, radius: 0.03 * s),
            materials: [SimpleMaterial(color: .white, isMetallic: false)]
        )
        pole.position.y = 1.5 * s
        pole.components.set(GroundingShadowComponent(castsShadow: true))
        flag.addChild(pole)

        let color = Self.flagColors[yards] ?? .white
        let cloth = ModelEntity(
            mesh: .generateBox(width: 0.9 * s, height: 0.6 * s, depth: 0.01),
            materials: [SimpleMaterial(color: color, isMetallic: false)]
        )
        cloth.position = [0.45 * s, 2.7 * s, 0]
        flag.addChild(cloth)

        let label = Self.makeSign("\(yards)", accent: color, height: 1.1 * s)
        label.position.y = 3.9 * s
        flag.addChild(label)

        root.addChild(flag)
    }

    // billboard text, always faces you
    // one sign style for every number in the range: dark rounded plate (reads against bright
    // sky), big white number, smaller unit, colored accent bar + optional caption above.
    // `height` = how tall the number is in meters. always turns to face u
    static func makeSign(_ value: String, unit: String? = "yd", caption: String? = nil, accent: UIColor, height: Float) -> Entity {
        func text(_ t: String, size: CGFloat, weight: UIFont.Weight) -> MeshResource {
            .generateText(t, extrusionDepth: 0.005, font: .systemFont(ofSize: size, weight: weight),
                          containerFrame: .zero, alignment: .left, lineBreakMode: .byClipping)
        }
        let content = Entity()
        let numMesh = text(value, size: 1, weight: .heavy)
        let num = ModelEntity(mesh: numMesh, materials: [UnlitMaterial(color: .white)])
        let nb = numMesh.bounds
        num.position = [-nb.min.x, -nb.min.y, 0]
        content.addChild(num)
        var right = nb.extents.x
        var top = nb.extents.y

        if let unit {
            let m = text(unit, size: 0.42, weight: .bold)
            let e = ModelEntity(mesh: m, materials: [UnlitMaterial(color: UIColor(white: 0.85, alpha: 1))])
            e.position = [right + 0.1 - m.bounds.min.x, -m.bounds.min.y, 0]
            content.addChild(e)
            right += 0.1 + m.bounds.extents.x
        }
        if let caption {
            let m = text(caption.uppercased(), size: 0.34, weight: .heavy)
            let e = ModelEntity(mesh: m, materials: [UnlitMaterial(color: accent)])
            e.position = [-m.bounds.min.x, top + 0.14 - m.bounds.min.y, 0]
            content.addChild(e)
            right = max(right, m.bounds.extents.x)
            top += 0.14 + m.bounds.extents.y
        }

        let pad: Float = 0.26
        let bar: Float = 0.1
        let gap: Float = 0.16  // bar -> text
        let left = -(gap + bar + 0.14)
        let w = right + pad - left
        let h = top + pad * 2
        // plate + accent bar behind the text
        var plateMat = UnlitMaterial(color: UIColor(white: 0.05, alpha: 1))
        plateMat.blending = .transparent(opacity: .init(floatLiteral: 0.62))
        let plate = ModelEntity(mesh: .generatePlane(width: w, height: h, cornerRadius: min(0.3, h / 2)), materials: [plateMat])
        plate.position = [(left + right + pad) / 2, top / 2, -0.02]
        let accentBar = ModelEntity(mesh: .generatePlane(width: bar, height: h - pad, cornerRadius: bar / 2), materials: [UnlitMaterial(color: accent)])
        accentBar.position = [-gap - bar / 2, top / 2, -0.01]
        content.addChild(plate)
        content.addChild(accentBar)
        // center the whole sign on the holder
        content.position = [-(left + right + pad) / 2, -top / 2, 0]

        let holder = Entity()
        holder.scale = .init(repeating: height)
        holder.addChild(content)
        holder.components.set(BillboardComponent())
        return holder
    }
}
