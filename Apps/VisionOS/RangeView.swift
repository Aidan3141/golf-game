import Foundation
import RealityKit
import SwiftUI

struct RangeView: View {
    @Environment(AppModel.self) private var appModel
    @State private var scene: RangeScene?
    @State private var playedShotID: UUID?

    var body: some View {
        RealityView { content in
            let s = await RangeScene()
            content.add(s.root)
            scene = s
            #if DEBUG
            // `-sideView`: turn the world so the sim camera sees the shot from the side
            if ProcessInfo.processInfo.arguments.contains("-sideView") {
                s.root.orientation = simd_quatf(angle: .pi * 0.25, axis: [0, 1, 0])
                s.root.position = [60, -10, 40]
            }
            #endif
            // shot may have come in while scene was loading
            if let shot = appModel.lastShot {
                play(shot, in: s)
            }
        }
        .onChange(of: appModel.lastShot) { _, shot in
            guard let shot, let scene else { return }
            play(shot, in: scene)
        }
    }

    private func play(_ shot: Shot, in scene: RangeScene) {
        guard shot.id != playedShotID else { return }
        playedShotID = shot.id
        scene.clearEffects()
        scene.resetBall()
        scene.ball.components.set(BallFlightComponent(flight: shot.flight, effects: scene.effects))
    }
}
