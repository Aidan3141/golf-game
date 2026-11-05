import Foundation
import RealityKit
import SwingKit
import UIKit

// small green on ur real floor. local coords like the range: target = -z, golfer on the -x side (rh).
// whole thing gets turned so the putter pivot is where u stand
@MainActor
final class PuttingScene {
    nonisolated static let groundY: Float = 0.01  // green top
    nonisolated static let ballRadius = Float(PuttTuning.standard.ballRadius)
    nonisolated static let ballStart = SIMD3<Float>(0, groundY + ballRadius, 0)

    let root = Entity()
    let ball: ModelEntity
    let club = ClubRig()
    private let holeRoot = Entity()
    private let greenRoot = Entity()

    init() {
        ball = ModelEntity(
            mesh: .generateSphere(radius: Self.ballRadius),
            materials: [SimpleMaterial(color: .white, roughness: 0.35, isMetallic: false)]
        )
        ball.components.set(GroundingShadowComponent(castsShadow: true))
        root.addChild(greenRoot)
        root.addChild(holeRoot)
        root.addChild(ball)
        root.addChild(club.root)
        resetBall()
    }

    // putt coords (x right of line, z toward hole) -> local
    nonisolated static func local(_ p: SIMD3<Double>) -> SIMD3<Float> {
        SIMD3(Float(p.x), Float(p.y) + groundY + ballRadius, -Float(p.z))
    }

    func resetBall() {
        ball.components.remove(PuttRollComponent.self)
        ball.position = Self.ballStart
        ball.isEnabled = true
    }

    func layout(_ setup: PuttSetup, hand: Handedness) async {
        let hole = SIMD3<Float>(Float(setup.hole.x), 0, -Float(setup.hole.y))
        await buildGreen(to: hole)
        buildHole(at: hole)
        club.setUp(for: hand, ball: Self.ballStart, putter: true)
        let t = club.firstPersonTransform(hand: hand)
        root.orientation = t.orientation
        root.position = t.position
        resetBall()
    }

    // rounded slab from behind the ball to past the hole + a darker fringe ring
    private func buildGreen(to hole: SIMD3<Float>) async {
        greenRoot.children.removeAll()
        let length = abs(hole.z) + 1.6
        let width: Float = 1.8
        let center = SIMD3<Float>(hole.x / 2, Self.groundY / 2, hole.z / 2)

        var green = PhysicallyBasedMaterial()
        green.baseColor = .init(tint: UIColor(red: 0.30, green: 0.62, blue: 0.26, alpha: 1))
        green.roughness = 0.85
        if let url = Bundle.main.url(forResource: "grass_diff", withExtension: "jpg"),
           let tex = try? await TextureResource(contentsOf: url, options: .init(semantic: .color)) {
            // super fine tile = short cut grass
            green.baseColor = .init(tint: UIColor(red: 0.55, green: 0.95, blue: 0.45, alpha: 1), texture: .init(tex))
            green.textureCoordinateTransform = .init(scale: [width / 0.5, length / 0.5])
        }
        let slab = ModelEntity(
            mesh: .generateBox(width: width, height: Self.groundY, depth: length, cornerRadius: 0.005),
            materials: [green]
        )
        slab.position = center
        greenRoot.addChild(slab)

        var fringe = PhysicallyBasedMaterial()
        fringe.baseColor = .init(tint: UIColor(red: 0.18, green: 0.40, blue: 0.16, alpha: 1))
        fringe.roughness = 0.95
        let f = ModelEntity(
            mesh: .generateBox(width: width + 0.3, height: Self.groundY * 0.6, depth: length + 0.3, cornerRadius: 0.003),
            materials: [fringe]
        )
        f.position = center - [0, 0.002, 0]
        greenRoot.addChild(f)
    }

    private func buildHole(at p: SIMD3<Float>) {
        holeRoot.children.removeAll()
        holeRoot.position = p
        let cupR = Float(PuttTuning.standard.cupRadius)
        let cup = ModelEntity(
            mesh: .generateCylinder(height: 0.002, radius: cupR),
            materials: [UnlitMaterial(color: UIColor(white: 0.02, alpha: 1))]
        )
        cup.position.y = Self.groundY + 0.0005
        holeRoot.addChild(cup)

        // white liner ring so the cup reads at a glance
        let rim = ModelEntity(
            mesh: .generateCylinder(height: 0.0015, radius: cupR + 0.006),
            materials: [UnlitMaterial(color: UIColor(white: 0.95, alpha: 1))]
        )
        rim.position.y = Self.groundY + 0.0002
        holeRoot.addChild(rim)

        let stick = ModelEntity(
            mesh: .generateCylinder(height: 1.1, radius: 0.006),
            materials: [SimpleMaterial(color: .white, isMetallic: false)]
        )
        stick.position = [0, Self.groundY + 0.55, 0]
        holeRoot.addChild(stick)
        let flag = ModelEntity(
            mesh: .generateBox(width: 0.28, height: 0.18, depth: 0.005),
            materials: [SimpleMaterial(color: .systemRed, isMetallic: false)]
        )
        flag.position = [0.14, Self.groundY + 1.0, 0]
        holeRoot.addChild(flag)
    }
}

// plays a precomputed roll on the ball
struct PuttRollComponent: Component {
    var points: [SIMD3<Float>]
    var times: [Float]
    var holed: Bool
    var elapsed: Float = 0
    var index = 0
    var started = false
    var dropped = false

    init(_ r: PuttResult) {
        points = r.points.map { PuttingScene.local($0.position) }
        times = r.points.map { Float($0.time) }
        holed = r.holed
    }
}

struct PuttRollSystem: System {
    static let query = EntityQuery(where: .has(PuttRollComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let dt = Float(context.deltaTime)
        for ball in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard var r = ball.components[PuttRollComponent.self] else { continue }
            r.elapsed += dt
            while r.index < r.points.count - 1 && r.times[r.index + 1] <= r.elapsed {
                r.index += 1
            }
            let pos: SIMD3<Float>
            if r.index >= r.points.count - 1 {
                pos = r.points[r.points.count - 1]
            } else {
                let t0 = r.times[r.index], t1 = r.times[r.index + 1]
                let u = min(max((r.elapsed - t0) / max(t1 - t0, 0.0001), 0), 1)
                pos = mix(r.points[r.index], r.points[r.index + 1], t: u)
            }
            ball.position = pos
            MainActor.assumeIsolated {
                if !r.started {
                    r.started = true
                    if let parent = ball.parent {
                        GameAudio.shared.play(GameAudio.shared.tick, at: r.points[0], in: parent, gain: -2)
                    }
                }
                if r.holed && !r.dropped && pos.y < PuttingScene.ballStart.y - 0.005 {
                    r.dropped = true
                    if let parent = ball.parent {
                        GameAudio.shared.play(GameAudio.shared.tock, at: pos, in: parent, gain: 0)
                    }
                }
                if r.index >= r.points.count - 1 {
                    if r.holed { ball.isEnabled = false }  // its in the cup
                    ball.components.remove(PuttRollComponent.self)
                } else {
                    ball.components.set(r)
                }
            }
        }
    }
}
