import Foundation
import RealityKit

// all the range sounds. made by tools/make_sounds.py
@MainActor
final class GameAudio {
    static let shared = GameAudio()

    private(set) var impact: AudioFileResource?
    private(set) var land: AudioFileResource?
    private(set) var ambience: AudioFileResource?
    private(set) var tick: AudioFileResource?
    private(set) var tock: AudioFileResource?

    func load() async {
        guard impact == nil else { return }
        impact = await Self.load("impact")
        land = await Self.load("land")
        ambience = await Self.load("ambience", loop: true)
        tick = await Self.load("tick")
        tock = await Self.load("tock")
    }

    private static func load(_ name: String, loop: Bool = false) async -> AudioFileResource? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return nil }
        return try? await AudioFileResource(contentsOf: url, configuration: .init(shouldLoop: loop))
    }

    // one shot spatial sound at a spot, cleans itself up
    func play(_ res: AudioFileResource?, at p: SIMD3<Float>, in parent: Entity, gain: Float = 0) {
        guard let res else { return }
        let e = Entity()
        e.position = p
        e.components.set(SpatialAudioComponent(gain: Audio.Decibel(gain)))
        parent.addChild(e)
        let ctrl = e.playAudio(res)
        ctrl.completionHandler = { [weak e] in e?.removeFromParent() }
    }
}

// 3 soft ticks on the way back, tock where impact should land for a perfect 3:1
@MainActor
final class TempoTrainer {
    private let speaker = Entity()
    private var task: Task<Void, Never>?

    init(parent: Entity) {
        speaker.components.set(AmbientAudioComponent(gain: -4))
        parent.addChild(speaker)
    }

    var isRunning: Bool { task != nil }

    func start(backswing: Double) {
        stop()
        task = Task { [speaker] in
            let beat = backswing / 3
            while !Task.isCancelled {
                for _ in 0..<3 {
                    if let t = GameAudio.shared.tick { speaker.playAudio(t) }
                    try? await Task.sleep(for: .seconds(beat))
                }
                // top is here, downswing is 1 beat
                try? await Task.sleep(for: .seconds(beat))
                if let t = GameAudio.shared.tock { speaker.playAudio(t) }
                try? await Task.sleep(for: .seconds(2.0))  // reset time between reps
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
