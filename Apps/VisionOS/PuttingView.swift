import Foundation
import RealityKit
import SwiftUI
import SwingKit

struct PuttingView: View {
    @Environment(AppModel.self) private var appModel
    @State private var scene: PuttingScene?
    @State private var playedID: UUID?
    @State private var handClub: HandClub?

    var body: some View {
        RealityView { content, attachments in
            let s = PuttingScene()
            content.add(s.root)
            scene = s
            await s.layout(appModel.puttSetup, hand: appModel.handedness)
            #if DEBUG
            // `-raise`: lift it so the fixed sim camera can see the green
            if ProcessInfo.processInfo.arguments.contains("-raise") {
                s.root.position.y += 1.15
                s.root.position.z -= 0.6
            }
            #endif
            s.club.root.components.set(LiveClubComponent(live: LiveClubRef(live: appModel.liveClub), rig: ClubRigRef(rig: s.club)))
            let hc = HandClub(putter: true)
            hc.ball = s.ball
            hc.sceneRoot = s.root
            hc.rig = s.club
            hc.appModel = appModel
            hc.minContactSpeed = 0.15  // putts are slow
            hc.driver.components.set(HandClubComponent(ref: HandClubRef(club: hc)))
            content.add(hc.driver)
            content.add(hc.freeRoot)
            // palm anchors go straight in the content, the renderer tracks them
            content.add(hc.leftAnchor)
            content.add(hc.rightAnchor)
            handClub = hc
            if let card = attachments.entity(for: "card") {
                card.name = "card"
                content.add(card)
            }
        } update: { content, _ in
            if let card = content.entities.first(where: { $0.name == "card" }) {
                // trail side, waist high so u see it looking down at the ball
                let side: Float = appModel.handedness == .right ? 1 : -1
                card.position = [0.55 * side, 1.0, -0.8]
                card.orientation = simd_quatf(angle: -0.5 * side, axis: [0, 1, 0]) * simd_quatf(angle: -0.35, axis: [1, 0, 0])
                card.isEnabled = appModel.puttCard != nil
            }
        } attachments: {
            Attachment(id: "card") {
                if let p = appModel.puttCard {
                    PuttCard(putt: p)
                }
            }
        }
        .task(id: scene == nil) {
            guard let scene else { return }
            await snapLoop(club: scene.club, root: scene.root)
        }
        .onChange(of: appModel.addressCheckOn, initial: true) { _, on in
            if on { appModel.startHandTracking() } else { appModel.stopHandTracking() }
        }
        .onChange(of: appModel.handBackend) { _, _ in
            handClub?.reset()
            if appModel.addressCheckOn { appModel.startHandTracking() }
        }
        .onDisappear { appModel.stopHandTracking() }
        .onChange(of: appModel.puttSetup) { _, setup in
            Task { await scene?.layout(setup, hand: appModel.handedness) }
        }
        .onChange(of: appModel.handedness) { _, hand in
            Task { await scene?.layout(appModel.puttSetup, hand: hand) }
            handClub?.reset()
        }
        .onChange(of: appModel.lastPutt) { _, p in
            // watch tempo came in for a putt thats already rolling, just update the card
            if let p, p.refined, p.id == playedID {
                if appModel.puttCard?.id == p.id { appModel.puttCard = p }
                return
            }
            guard let p, let scene, p.id != playedID else { return }
            playedID = p.id
            appModel.puttCard = nil
            scene.resetBall()
            scene.ball.components.set(PuttRollComponent(p.result))
            Task {
                try? await Task.sleep(for: .seconds(p.result.duration + 0.3))
                guard let latest = appModel.lastPutt, latest.id == p.id else { return }
                appModel.puttCard = latest
                if p.result.holed {
                    appModel.holed()
                } else {
                    // putt it from where it stopped? keep it simple, back to the start
                    try? await Task.sleep(for: .seconds(1.5))
                    if appModel.lastPutt?.id == p.id { scene.resetBall() }
                }
            }
        }
    }
}

extension PuttingView {

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
}

struct PuttCard: View {
    let putt: PuttShot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(headline)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(putt.result.holed ? .green : .primary)
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tempo").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.1f : 1", putt.swing.tempoRatio))
                        .font(.title2.bold())
                        .foregroundStyle(Coach.puttTempoGood ~= putt.swing.tempoRatio ? .green : .orange)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Goal").font(.caption).foregroundStyle(.secondary)
                    Text("2 : 1").font(.title2.bold())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Putt").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.0f ft", putt.setup.distance * 3.28084)).font(.title2.bold())
                }
            }
            Text(putt.tip.title).font(.headline)
            Text(putt.tip.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 420)
        .glassBackgroundEffect()
    }

    private var headline: String {
        if putt.result.holed { return "In! 🎉" }
        let ft = putt.result.leftToHole * 3.28084
        let along = putt.result.rest.y - putt.setup.hole.y
        return String(format: "%.1f ft %@", ft, along < 0 ? "short" : "past")
    }
}
