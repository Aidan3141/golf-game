import CoreMotion
import Foundation
import Observation
import SwingKit
import WatchKit

// streams sensors into ring buffers while a session runs, then slices out recordings.
// timestamps are secs since boot (same clock as ProcessInfo.systemUptime)
@MainActor
@Observable
final class MotionCapture {
    enum RecordState: Equatable {
        case ready
        case countdown(Int)
        case recording
        case saving
        case saved
        case failed(String)
    }

    static let recordSeconds = 3.0
    static let bufferSeconds = 10.0

    private(set) var isStreaming = false
    private(set) var source = "none"
    private(set) var accelHz = 0.0
    private(set) var motionHz = 0.0
    private(set) var recordState = RecordState.ready
    private(set) var lastRecording: SwingRecording?
    var errorText: String?

    // live detection
    private(set) var phase = SwingPhase.idle
    private(set) var lastSwing: SwingResult?
    private(set) var lastRejected: String?
    private(set) var swingCount = 0
    var handedness = Handedness.right {
        didSet { detector.handedness = handedness }
    }
    // fires right at impact w/ confident swings, this is what launches the ball
    @ObservationIgnored var onImpact: ((SwingResult) -> Void)?
    // live club angle for the headset, throttled to ~25hz while ur addressed/swinging
    @ObservationIgnored var onClubAngle: ((Double, SwingPhase) -> Void)?
    @ObservationIgnored private var lastAngleSent = 0.0
    static let angleInterval = 1.0 / 30  // offered rate, the ack gate decides what actually goes

    // raw data around each swing, ~1-2s later once batched data lands (if saveSwingData)
    @ObservationIgnored var onSwingData: ((SwingRecording) -> Void)?
    var saveSwingData = true
    var tempoTaps = false
    // full swing or putting, avp sets this thru the phone (or the picker on the watch)
    var mode = SwingMode.full {
        didSet {
            guard mode != oldValue else { return }
            detector.config = mode == .putt ? .putting : .standard
            detector.reset()
            phase = .idle
            lastSwing = nil
            lastRejected = nil
        }
    }
    var tempoBackswing = 0.9  // s
    @ObservationIgnored private var tapTask: Task<Void, Never>?

    @ObservationIgnored private var accelBuffer = RingBuffer<AccelSample>(capacity: 8_000)
    @ObservationIgnored private var motionBuffer = RingBuffer<MotionFrame>(capacity: 2_000)
    @ObservationIgnored private var batched: CMBatchedSensorManager?
    @ObservationIgnored private let fallback = CMMotionManager()
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var detector = SwingDetector()
    @ObservationIgnored private let live = CMMotionManager()

    var isBusy: Bool {
        switch recordState {
        case .countdown, .recording, .saving: true
        default: false
        }
    }

    // MARK: streaming

    func startStreaming() {
        guard !isStreaming else { return }
        accelBuffer.removeAll()
        motionBuffer.removeAll()
        detector.reset()
        phase = .idle
        if CMBatchedSensorManager.isAccelerometerSupported && CMBatchedSensorManager.isDeviceMotionSupported {
            startBatched()
        } else {
            startFallback()
        }
        startLive()
        isStreaming = true
    }

    func stopStreaming() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        batched?.stopAccelerometerUpdates()
        batched?.stopDeviceMotionUpdates()
        batched = nil
        fallback.stopAccelerometerUpdates()
        fallback.stopDeviceMotionUpdates()
        live.stopDeviceMotionUpdates()
        isStreaming = false
        phase = .idle
    }

    // MARK: live detection

    // batched data lands ~1s late, too laggy for the impact tap. so detection runs on a
    // separate 100hz device motion stream, timestamps share the same clock
    private func startLive() {
        live.deviceMotionUpdateInterval = 1 / 100
        live.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let f = Self.frame(motion)
            let g = AccelSample(
                t: motion.timestamp,
                x: motion.userAcceleration.x + motion.gravity.x,
                y: motion.userAcceleration.y + motion.gravity.y,
                z: motion.userAcceleration.z + motion.gravity.z
            )
            MainActor.assumeIsolated { self?.handleLive(f, accel: g) }
        }
    }

    private func handleLive(_ f: MotionFrame, accel: AccelSample) {
        // fallback mode shares this stream for the buffers
        if source == "motionManager" {
            motionBuffer.append(f)
        }
        detector.add(accel: [accel])
        let events = detector.add(motion: [f])
        phase = detector.phase
        if let a = detector.currentAngle, f.t - lastAngleSent >= Self.angleInterval {
            lastAngleSent = f.t
            onClubAngle?(a, detector.phase)
        }
        let device = WKInterfaceDevice.current()
        for e in events {
            switch e {
            case .address:
                device.play(.click)
                if tempoTaps { playTempoTaps() }
            case .takeaway:
                break
            case .impact(let result, let timeline):
                tapTask?.cancel()
                // double tap = nice tempo, plain strong tap otherwise
                let good = mode == .putt ? Coach.puttTempoGood : Coach.tempoGood
                device.play(good ~= result.tempoRatio ? .success : .notification)
                swingCount += 1
                if result.confidence >= detector.config.minConfidenceToSend {
                    lastSwing = result
                    lastRejected = nil
                    onImpact?(result)
                } else {
                    lastRejected = "not sure that was a swing"
                }
                Task { await self.deliver(result, timeline: timeline) }
            case .rejected(let reason, _):
                lastRejected = reason
            }
        }
    }

    // haptic metronome after address: tick tick tick (back), tap (impact) = 3:1
    private func playTempoTaps() {
        tapTask?.cancel()
        // full = 3 back 1 down (3:1), putt = 2 back 1 thru (2:1)
        let beats = mode == .putt ? 2 : 3
        let back = mode == .putt ? 0.6 : tempoBackswing
        let beat = back / Double(beats)
        tapTask = Task {
            try? await Task.sleep(for: .seconds(0.6))
            let device = WKInterfaceDevice.current()
            for _ in 0..<beats {
                guard !Task.isCancelled else { return }
                device.play(.click)
                try? await Task.sleep(for: .seconds(beat))
            }
            try? await Task.sleep(for: .seconds(beat))
            guard !Task.isCancelled else { return }
            device.play(.directionUp)
        }
    }

    // wait for the batched data around the swing, then hand it off
    private func deliver(_ result: SwingResult, timeline: SwingTimeline) async {
        guard saveSwingData, !isBusy else { return }
        let start = timeline.impact - 2.5
        let end = timeline.impact + 0.8
        await waitForData(until: end)
        guard let rec = slice(start: start, end: end, wallStart: Date.now.addingTimeInterval(start - ProcessInfo.processInfo.systemUptime),
                        note: String(format: "auto, tempo %.2f, conf %.2f", result.tempoRatio, result.confidence)) else { return }
        onSwingData?(rec)
    }

    // high rate, needs an active workout session. data shows up in ~1s batches
    private func startBatched() {
        let m = CMBatchedSensorManager()
        batched = m
        source = "batched"
        accelHz = Double(m.accelerometerDataFrequency)
        motionHz = Double(m.deviceMotionDataFrequency)

        tasks.append(Task { [weak self] in
            do {
                for try await batch in m.accelerometerUpdates() {
                    let samples = batch.map {
                        AccelSample(t: $0.timestamp, x: $0.acceleration.x, y: $0.acceleration.y, z: $0.acceleration.z)
                    }
                    self?.accelBuffer.append(contentsOf: samples)
                }
            } catch {
                self?.errorText = "accel: \(error.localizedDescription)"
            }
        })
        tasks.append(Task { [weak self] in
            do {
                for try await batch in m.deviceMotionUpdates() {
                    let frames = batch.map(Self.frame)
                    self?.motionBuffer.append(contentsOf: frames)
                }
            } catch {
                self?.errorText = "motion: \(error.localizedDescription)"
            }
        })
    }

    // backup if batched isnt there, ~100hz max
    private func startFallback() {
        source = "motionManager"
        let hz = 100.0
        fallback.accelerometerUpdateInterval = 1 / hz
        accelHz = hz
        motionHz = hz
        fallback.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            let s = AccelSample(t: data.timestamp, x: data.acceleration.x, y: data.acceleration.y, z: data.acceleration.z)
            MainActor.assumeIsolated { self?.accelBuffer.append(s) }
        }
        // device motion comes from the live stream (see handleLive)
    }

    nonisolated private static func frame(_ m: CMDeviceMotion) -> MotionFrame {
        let q = m.attitude.quaternion
        return MotionFrame(
            t: m.timestamp,
            rotX: m.rotationRate.x, rotY: m.rotationRate.y, rotZ: m.rotationRate.z,
            userX: m.userAcceleration.x, userY: m.userAcceleration.y, userZ: m.userAcceleration.z,
            gravX: m.gravity.x, gravY: m.gravity.y, gravZ: m.gravity.z,
            qw: q.w, qx: q.x, qy: q.y, qz: q.z
        )
    }

    // MARK: recording

    // 3-2-1 taps, record 3s, wait for the batch to land, slice it out
    func record() async -> SwingRecording? {
        guard isStreaming, !isBusy else { return nil }
        let device = WKInterfaceDevice.current()

        for n in [3, 2, 1] {
            recordState = .countdown(n)
            device.play(.click)
            try? await Task.sleep(for: .seconds(1))
        }

        recordState = .recording
        device.play(.start)
        let wallStart = Date.now
        let start = ProcessInfo.processInfo.systemUptime
        let end = start + Self.recordSeconds
        try? await Task.sleep(for: .seconds(Self.recordSeconds))
        device.play(.stop)

        recordState = .saving
        await waitForData(until: end)
        guard let rec = slice(start: start, end: end, wallStart: wallStart, note: "manual") else {
            recordState = .failed("no sensor data")
            device.play(.failure)
            return nil
        }
        lastRecording = rec
        recordState = .saved
        device.play(.success)
        return rec
    }

    // batches lag ~1s, wait till both streams cover the window (or give up after 4s)
    private func waitForData(until end: Double) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while ProcessInfo.processInfo.systemUptime < deadline {
            let a = accelBuffer.elements.last?.t ?? 0
            let m = motionBuffer.elements.last?.t ?? 0
            if a >= end && m >= end { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func slice(start: Double, end: Double, wallStart: Date, note: String) -> SwingRecording? {
        let accel = accelBuffer.elements
            .filter { $0.t >= start && $0.t <= end }
            .map { AccelSample(t: $0.t - start, x: $0.x, y: $0.y, z: $0.z) }
        let motion = motionBuffer.elements
            .filter { $0.t >= start && $0.t <= end }
            .map { f -> MotionFrame in
                var f = f
                f.t -= start
                return f
            }
        guard !accel.isEmpty || !motion.isEmpty else { return nil }
        return SwingRecording(
            startedAt: wallStart,
            duration: end - start,
            handedness: handedness,
            wrist: WKInterfaceDevice.current().wristLocation == .left ? "left" : "right",
            source: source,
            accelHz: accelHz,
            motionHz: motionHz,
            accel: accel,
            motion: motion,
            note: note
        )
    }
}
