import RealityKit
import SwingKit
import UIKit

// put this on the ball to play a precomputed flight
struct BallFlightComponent: Component {
    var points: [SIMD3<Float>]
    var times: [Float]
    var landingIndex: Int
    var carryYards: Double
    var totalYards: Double
    var effects: Entity  // where trail + markers go

    var elapsed: Float = 0
    var index = 0
    var lastTrailPoint: SIMD3<Float>?
    var landed = false
    var launched = false
    // after a refine: where the ball was minus where the new path says, fades out
    var blendOffset = SIMD3<Float>.zero
    var blendLeft: Float = 0
    static let blendTime: Float = 0.35

    // swap in a better flight mid air (watch numbers came in after a hand contact launch)
    mutating func retarget(_ flight: FlightResult, currentPosition: SIMD3<Float>) {
        points = flight.points.map { RangeScene.scenePoint($0.position) }
        times = flight.points.map { Float($0.time) }
        landingIndex = flight.landingIndex
        carryYards = Units.yards(flight.carry)
        totalYards = Units.yards(flight.total)
        index = 0
        while index < points.count - 1 && times[index + 1] <= elapsed { index += 1 }
        blendOffset = currentPosition - points[index]
        blendLeft = Self.blendTime
    }

    init(flight: FlightResult, effects: Entity) {
        points = flight.points.map { RangeScene.scenePoint($0.position) }
        times = flight.points.map { Float($0.time) }
        landingIndex = flight.landingIndex
        carryYards = Units.yards(flight.carry)
        totalYards = Units.yards(flight.total)
        self.effects = effects
    }
}

struct BallFlightSystem: System {
    static let query = EntityQuery(where: .has(BallFlightComponent.self))
    static let headPosition = SIMD3<Float>(0, 1.5, 0)  // rough, good enough for scaling

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let dt = Float(context.deltaTime)
        for ball in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard var f = ball.components[BallFlightComponent.self] else { continue }
            f.elapsed += dt

            while f.index < f.points.count - 1 && f.times[f.index + 1] <= f.elapsed {
                f.index += 1
            }

            let pos: SIMD3<Float>
            if f.index >= f.points.count - 1 {
                pos = f.points[f.points.count - 1]
            } else {
                let t0 = f.times[f.index], t1 = f.times[f.index + 1]
                let u = min(max((f.elapsed - t0) / max(t1 - t0, 0.0001), 0), 1)
                pos = mix(f.points[f.index], f.points[f.index + 1], t: u)
            }
            var shown = pos
            if f.blendLeft > 0 {
                shown += f.blendOffset * (f.blendLeft / BallFlightComponent.blendTime)
                f.blendLeft -= dt
            }
            ball.position = shown

            // real ball is 4cm, invisible at 150 yd. grow it w/ distance so u can follow it
            let dist = simd_distance(ball.position(relativeTo: nil), Self.headPosition)
            ball.scale = .init(repeating: max(1, dist / 9))

            // systems run on main thread, text meshes need main actor
            MainActor.assumeIsolated {
                if !f.launched {
                    f.launched = true
                    GameAudio.shared.play(GameAudio.shared.impact, at: f.points[0], in: f.effects, gain: 4)
                }
                if !f.landed {
                    addTrail(&f, to: pos, dist: dist)
                }

                if !f.landed && f.index >= f.landingIndex {
                    f.landed = true
                    // boosted, its usually 150m away
                    GameAudio.shared.play(GameAudio.shared.land, at: f.points[f.landingIndex], in: f.effects, gain: 18)
                    Self.addMarker(at: f.points[f.landingIndex], text: String(format: "%.0f carry", f.carryYards),
                                   color: .systemYellow, in: f.effects)
                }

                if f.index >= f.points.count - 1 {
                    Self.addMarker(at: pos, text: String(format: "%.0f yd", f.totalYards), color: .white, in: f.effects)
                    ball.components.remove(BallFlightComponent.self)
                } else {
                    ball.components.set(f)
                }
            }
        }
    }

    // thin cylinder from last trail point to here
    @MainActor
    private func addTrail(_ f: inout BallFlightComponent, to pos: SIMD3<Float>, dist: Float) {
        guard let last = f.lastTrailPoint else {
            f.lastTrailPoint = pos
            return
        }
        let seg = pos - last
        let len = simd_length(seg)
        guard len > 0.6 else { return }

        var mat = UnlitMaterial(color: .white)
        mat.blending = .transparent(opacity: .init(floatLiteral: 0.75))
        let radius = 0.015 + dist * 0.0018
        let piece = ModelEntity(mesh: .generateCylinder(height: len, radius: radius), materials: [mat])
        piece.position = (last + pos) / 2
        piece.orientation = simd_quatf(from: [0, 1, 0], to: seg / len)
        f.effects.addChild(piece)
        f.lastTrailPoint = pos
    }

    @MainActor
    private static func addMarker(at p: SIMD3<Float>, text: String, color: UIColor, in parent: Entity) {
        let dist = simd_distance(parent.convert(position: p, to: nil), headPosition)
        let s = max(1, dist / 40)
        let ring = ModelEntity(
            mesh: .generateCylinder(height: 0.02, radius: 0.8 * s),
            materials: [UnlitMaterial(color: color.withAlphaComponent(0.85))]
        )
        ring.position = [p.x, 0.02, p.z]
        parent.addChild(ring)

        let label = RangeScene.makeLabel(text, height: 0.8 * s, color: color)
        label.position = [p.x, 2.2 * s, p.z]
        parent.addChild(label)
    }
}
