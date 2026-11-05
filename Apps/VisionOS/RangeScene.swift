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
            let q = simd_quatf(angle: hand == .right ? .pi / 2 : -.pi / 2, axis: [0, 1, 0])
            let p = q.act(club.root.position)
            root.orientation = q
            root.position = [-p.x, 0, -p.z]
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

    // MARK: sky + lighting

    private func addSky() async {
        // visible sky: big inside-out sphere w/ the 8k jpg
        if let url = Bundle.main.url(forResource: "sky_8k", withExtension: "jpg"),
           let tex = try? await TextureResource(contentsOf: url, options: .init(semantic: .color)) {
            var mat = UnlitMaterial()
            mat.color = .init(tint: .white, texture: .init(tex))
            let sky = ModelEntity(mesh: .generateSphere(radius: 1900), materials: [mat])
            sky.scale = [-1, 1, 1]  // flip so we see the inside
            sky.orientation = simd_quatf(angle: .pi * 0.8, axis: [0, 1, 0])  // sun off to the side
            root.addChild(sky)
        }

        // lighting: image based light from the 2k hdr
        if let url = Bundle.main.url(forResource: "sky_2k", withExtension: "hdr"),
           let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
           let env = try? await EnvironmentResource(equirectangular: image, options: .init()) {
            iblRoot.components.set(ImageBasedLightComponent(source: .single(env), intensityExponent: 0.4))
            iblRoot.orientation = simd_quatf(angle: .pi * 0.8, axis: [0, 1, 0])
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
            color: await load("grass_diff", .color),
            normal: await load("grass_nor", .normal),
            roughness: await load("grass_rough", .raw)
        )
    }

    // texture is leafy/brown so tint it green. tile = meters per texture repeat
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

    private func addGround(_ grass: Grass) {
        let size: Float = 2600
        let rough = UIColor(red: 0.42, green: 0.62, blue: 0.30, alpha: 1)
        let ground = ModelEntity(
            mesh: .generatePlane(width: size, depth: size),
            materials: [grassMaterial(grass, tint: rough, size: [size, size], tile: 6)]
        )
        ground.position = [0, -0.01, 0]
        root.addChild(ground)
    }

    // mowed stripes down the target line
    private func addFairway(_ grass: Grass) {
        let stripeWidth: Float = 9
        let length: Float = 330
        let light = UIColor(red: 0.62, green: 0.85, blue: 0.45, alpha: 1)
        let dark = UIColor(red: 0.50, green: 0.74, blue: 0.36, alpha: 1)
        for i in -4..<4 {
            let stripe = ModelEntity(
                mesh: .generatePlane(width: stripeWidth, depth: length),
                materials: [grassMaterial(grass, tint: i.isMultiple(of: 2) ? light : dark, size: [stripeWidth, length])]
            )
            stripe.position = [(Float(i) + 0.5) * stripeWidth, 0, -length / 2 - 2]
            root.addChild(stripe)
        }
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
        greenMat.baseColor = .init(tint: UIColor(red: 0.45, green: 0.8, blue: 0.35, alpha: 1))
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

        let label = Self.makeLabel("\(yards)", height: 1.2 * s, color: .white)
        label.position.y = 3.9 * s
        flag.addChild(label)

        root.addChild(flag)
    }

    // billboard text, always faces you
    static func makeLabel(_ text: String, height: Float, color: UIColor) -> Entity {
        let mesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.01,
            font: .systemFont(ofSize: 1, weight: .heavy),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byClipping
        )
        let model = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])
        // center it, text mesh origin is bottom left-ish
        let b = mesh.bounds
        model.position = [-b.center.x, -b.center.y, 0]
        let holder = Entity()
        holder.scale = .init(repeating: height / max(b.extents.y, 0.001))
        holder.addChild(model)
        holder.components.set(BillboardComponent())
        return holder
    }
}
