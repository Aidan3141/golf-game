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
            s.applyView(appModel.viewMode, hand: appModel.handedness)
            s.club.root.components.set(LiveClubComponent(live: LiveClubRef(live: appModel.liveClub), rig: ClubRigRef(rig: s.club)))
            #if DEBUG
            // `-sideView`: turn the world so the sim camera sees the shot from the side
            if ProcessInfo.processInfo.arguments.contains("-sideView") {
                s.root.orientation = simd_quatf(angle: .pi * 0.25, axis: [0, 1, 0])
                s.root.position = [60, -10, 40]
            }
            // `-raise`: lift the world 1.1m so the fixed sim camera can see the ball + club
            if ProcessInfo.processInfo.arguments.contains("-raise") {
                s.root.position.y += 1.1
            }
            // `-clubView`: face-on look at the golfer spot to check the swing
            if ProcessInfo.processInfo.arguments.contains("-clubView") {
                s.root.orientation = simd_quatf(angle: -.pi / 2, axis: [0, 1, 0])
                s.root.position = SIMD3<Float>(0, 0, -3.2) - s.root.orientation.act(RangeScene.teePosition + [-0.55, 0, 0])
            }
            #endif
            // shot may have come in while scene was loading
            if let shot = appModel.lastShot {
                play(shot, in: s)
            }
        }
        .onChange(of: appModel.viewMode) { _, mode in
            scene?.applyView(mode, hand: appModel.handedness)
        }
        .onChange(of: appModel.handedness) { _, hand in
            scene?.applyView(appModel.viewMode, hand: hand)
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
        if shot.swing.handedness != appModel.handedness {
            appModel.testSwing.handedness = shot.swing.handedness
        }
        // live swing w/ the club streaming -> u already swung it, just launch
        if shot.live && appModel.liveClub.isFresh {
            scene.ball.components.set(BallFlightComponent(flight: shot.flight, effects: scene.effects))
            return
        }
        // otherwise club swings first, ClubSwingSystem launches the ball at impact
        scene.club.setPath(shot.swing.pathBias, hand: shot.swing.handedness)
        scene.club.root.components.set(
            ClubSwingComponent(shot: shot, ball: scene.ball, effects: scene.effects, rig: scene.club)
        )
    }
}
