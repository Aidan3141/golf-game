import Foundation
import RealityKit
import SwiftUI

struct RangeView: View {
    @Environment(AppModel.self) private var appModel
    @State private var scene: RangeScene?
    @State private var playedShotID: UUID?
    @State private var handClub: HandClub?
    @State private var launchedAt = Date.distantPast

    var body: some View {
        RealityView { content, attachments in
            let s = await RangeScene()
            content.add(s.root)
            scene = s
            s.applyView(appModel.viewMode, hand: appModel.handedness)
            s.club.root.components.set(LiveClubComponent(live: LiveClubRef(live: appModel.liveClub), rig: ClubRigRef(rig: s.club)))
            // club on ur real hands, world space
            let hc = HandClub(putter: false)
            hc.ball = s.ball
            hc.sceneRoot = s.root
            hc.rig = s.club
            hc.appModel = appModel
            hc.driver.components.set(HandClubComponent(ref: HandClubRef(club: hc)))
            content.add(hc.driver)
            content.add(hc.freeRoot)
            // palm anchors go straight in the content, the renderer tracks them
            content.add(hc.leftAnchor)
            content.add(hc.rightAnchor)
            handClub = hc
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
            if let card = attachments.entity(for: "card") {
                card.name = "card"
                content.add(card)
                placeCard(card)
            }
            if let shot = appModel.lastShot {
                play(shot, in: s)
            }
            if appModel.tempoTrainerOn {
                s.trainer.start(backswing: appModel.trainerBackswing)
            }
        } update: { content, _ in
            if let card = content.entities.first(where: { $0.name == "card" }) {
                placeCard(card)
                card.isEnabled = appModel.cardShot != nil
            }
        } attachments: {
            Attachment(id: "card") {
                if let shot = appModel.cardShot {
                    ShotCard(shot: shot)
                }
            }
        }
        .task(id: scene == nil) {
            guard let scene else { return }
            await snapLoop(club: scene.club, root: scene.root)
        }
        .onChange(of: appModel.tempoTrainerOn) { _, _ in updateTrainer() }
        .onChange(of: appModel.trainerBackswing) { _, _ in updateTrainer() }
        .onDisappear {
            scene?.trainer.stop()
            appModel.stopHandTracking()
        }
        .onChange(of: appModel.addressCheckOn, initial: true) { _, on in
            if on { appModel.startHandTracking() } else { appModel.stopHandTracking() }
        }
        .onChange(of: appModel.handBackend) { _, _ in
            handClub?.reset()
            if appModel.addressCheckOn { appModel.startHandTracking() }
        }
        .onChange(of: appModel.viewMode) { _, mode in
            scene?.applyView(mode, hand: appModel.handedness)
        }
        .onChange(of: appModel.handedness) { _, hand in
            scene?.applyView(appModel.viewMode, hand: hand)
            handClub?.reset()
        }
        .onChange(of: appModel.viewMode) { _, _ in handClub?.reset() }
        .onChange(of: appModel.lastShot) { _, shot in
            guard let shot, let scene else { return }
            play(shot, in: scene)
        }
    }

    private func updateTrainer() {
        guard let scene else { return }
        if appModel.tempoTrainerOn {
            scene.trainer.start(backswing: appModel.trainerBackswing)
        } else {
            scene.trainer.stop()
        }
    }

    // off to the side so it doesnt block the ball. world space, the range root moves but u dont
    private func placeCard(_ card: Entity) {
        switch appModel.viewMode {
        case .firstPerson:
            // ball flies to ur lead side, put the card on the other side
            let side: Float = appModel.handedness == .right ? 1 : -1
            card.position = [0.6 * side, 1.35, -1.0]
            card.orientation = simd_quatf(angle: -0.5 * side, axis: [0, 1, 0])
        case .behind:
            card.position = [1.0, 1.3, -1.6]
            card.orientation = simd_quatf(angle: -0.4, axis: [0, 1, 0])
        }
    }

    // card shows up when the ball lands
    private func showCard(for shot: Shot, after secs: Double) {
        appModel.cardShot = nil
        Task {
            try? await Task.sleep(for: .seconds(secs))
            // grab the latest version, it may have been refined mid flight
            if let latest = appModel.lastShot, latest.id == shot.id {
                appModel.cardShot = latest
            }
        }
    }

    // while hands are good + still at address, line the grip up w/ them
    private func snapLoop(club: ClubRig, root: Entity) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(300))
            let check = appModel.addressCheck
            guard appModel.addressCheckOn else {
                club.clearSnap()
                continue
            }
            let swinging = appModel.liveClub.isFresh && abs(appModel.liveClub.watchAngle) > 0.15
            guard !swinging, let mid = check.handsMid, let since = check.goodSince,
                  ProcessInfo.processInfo.systemUptime - since > 0.5 else { continue }
            club.snapGrip(toHands: root.convert(position: mid, from: nil))
        }
    }

    private func play(_ shot: Shot, in scene: RangeScene) {
        // watch numbers landed for a ball thats already flying -> bend it onto the real path
        if shot.refined && shot.id == playedShotID {
            if var f = scene.ball.components[BallFlightComponent.self] {
                f.retarget(shot.flight, currentPosition: scene.ball.position)
                scene.ball.components.set(f)
            }
            let landing = shot.flight.points[shot.flight.landingIndex].time + 0.3
            showCard(for: shot, after: max(landing - Date.now.timeIntervalSince(launchedAt), 0.1))
            return
        }
        guard shot.id != playedShotID else { return }
        playedShotID = shot.id
        launchedAt = .now
        let landing = shot.flight.points[shot.flight.landingIndex].time + 0.3
        scene.clearEffects()
        scene.resetBall()
        if shot.swing.handedness != appModel.handedness {
            appModel.testSwing.handedness = shot.swing.handedness
        }
        // hand club contact, or live swing w/ the club streaming -> u already swung it, just launch
        if shot.provisional || (shot.live && appModel.liveClub.isFresh) || handClub?.isActive == true {
            var f = BallFlightComponent(flight: shot.flight, effects: scene.effects)
            f.elapsed = Float(shot.startOffset)
            scene.ball.components.set(f)
            showCard(for: shot, after: max(landing - shot.startOffset, 0.1))
            return
        }
        // otherwise club swings first, ClubSwingSystem launches the ball at impact
        scene.club.setPath(shot.swing.pathBias, hand: shot.swing.handedness)
        let swing = ClubSwingComponent(shot: shot, ball: scene.ball, effects: scene.effects, rig: scene.club)
        scene.club.root.components.set(swing)
        showCard(for: shot, after: Double(max(swing.impactTime - swing.elapsed, 0)) + landing)
    }
}
