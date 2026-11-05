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

    @ObservationIgnored private var accelBuffer = RingBuffer<AccelSample>(capacity: 8_000)
    @ObservationIgnored private var motionBuffer = RingBuffer<MotionFrame>(capacity: 2_000)
    @ObservationIgnored private var batched: CMBatchedSensorManager?
    @ObservationIgnored private let fallback = CMMotionManager()
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

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
        if CMBatchedSensorManager.isAccelerometerSupported && CMBatchedSensorManager.isDeviceMotionSupported {
            startBatched()
        } else {
            startFallback()
        }
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
        isStreaming = false
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
        fallback.deviceMotionUpdateInterval = 1 / hz
        accelHz = hz
        motionHz = hz
        fallback.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            let s = AccelSample(t: data.timestamp, x: data.acceleration.x, y: data.acceleration.y, z: data.acceleration.z)
            MainActor.assumeIsolated { self?.accelBuffer.append(s) }
        }
        fallback.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let f = Self.frame(motion)
            MainActor.assumeIsolated { self?.motionBuffer.append(f) }
        }
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
    func record(handedness: Handedness) async -> SwingRecording? {
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
        // batches lag ~1s, wait till both streams cover the window (or give up after 4s)
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while ProcessInfo.processInfo.systemUptime < deadline {
            let a = accelBuffer.elements.last?.t ?? 0
            let m = motionBuffer.elements.last?.t ?? 0
            if a >= end && m >= end { break }
            try? await Task.sleep(for: .milliseconds(200))
        }

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

        guard !accel.isEmpty || !motion.isEmpty else {
            recordState = .failed("no sensor data")
            device.play(.failure)
            return nil
        }

        let rec = SwingRecording(
            startedAt: wallStart,
            duration: Self.recordSeconds,
            handedness: handedness,
            wrist: device.wristLocation == .left ? "left" : "right",
            source: source,
            accelHz: accelHz,
            motionHz: motionHz,
            accel: accel,
            motion: motion
        )
        lastRecording = rec
        recordState = .saved
        device.play(.success)
        return rec
    }
}
