import SwiftUI
import SwingKit

struct ContentView: View {
    @Environment(WorkoutManager.self) private var workout
    @Environment(MotionCapture.self) private var capture
    @Environment(WatchConnectivityManager.self) private var connectivity
    @AppStorage("handedness") private var handedness = Handedness.right
    @AppStorage("saveSwingData") private var saveSwingData = true
    @AppStorage("tempoTaps") private var tempoTaps = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if workout.isRunning {
                    Picker("Mode", selection: Binding(get: { capture.mode }, set: { capture.mode = $0 })) {
                        Text("Full swing").tag(SwingMode.full)
                        Text("Putting").tag(SwingMode.putt)
                    }
                    swingView
                    Divider()
                    recordButton
                    Toggle("Tempo taps", isOn: $tempoTaps)
                        .font(.footnote)
                    Toggle("Save swing data", isOn: $saveSwingData)
                        .font(.footnote)
                    status
                    Button("End Session", role: .destructive) {
                        capture.stopStreaming()
                        workout.stop()
                    }
                    .disabled(capture.isBusy)
                } else {
                    startView
                }
            }
            .padding(.horizontal, 4)
        }
        .onAppear {
            capture.handedness = handedness
            capture.saveSwingData = saveSwingData
            capture.tempoTaps = tempoTaps
            capture.onImpact = { [connectivity] swing in
                connectivity.send(swing: swing)
            }
            connectivity.onMode = { [capture] mode in
                capture.mode = mode
            }
            capture.onClubAngle = { [connectivity] angle, phase in
                connectivity.send(clubAngle: angle, phase: phase)
            }
            capture.onSwingData = { [connectivity] rec in
                connectivity.send(rec)
            }
        }
        .onChange(of: handedness) { _, h in capture.handedness = h }
        .onChange(of: saveSwingData) { _, v in capture.saveSwingData = v }
        .onChange(of: tempoTaps) { _, v in capture.tempoTaps = v }
        .onChange(of: workout.isRunning) { _, running in
            if running { capture.startStreaming() } else { capture.stopStreaming() }
        }
    }

    // big tempo readout from the last detected swing
    private var swingView: some View {
        VStack(spacing: 4) {
            Text(phaseText)
                .font(.headline)
                .foregroundStyle(phaseColor)
            if let s = capture.lastSwing {
                Text(String(format: "%.1f : 1", s.tempoRatio))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(tempoColor(s.tempoRatio, goal: capture.mode == .putt ? 2 : 3))
                Text(String(format: "back %.2fs · down %.2fs", s.backswingDuration, s.downswingDuration))
                    .font(.footnote)
                if let face = s.faceAngle {
                    Text(String(format: "wrist roll %+.0f°", face))
                        .font(.footnote)
                }
                Text(String(format: "%.0f rad/s · smooth %.0f%%", s.peakWristAngularVelocity, s.smoothnessScore * 100))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("take a swing")
                    .foregroundStyle(.secondary)
            }
            if let r = capture.lastRejected {
                Text(r).font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private var phaseText: String {
        switch capture.phase {
        case .idle: "Ready"
        case .address: "Address"
        case .backswing, .top, .downswing: "Swinging"
        case .impact, .followThrough: "Nice"
        }
    }

    private var phaseColor: Color {
        switch capture.phase {
        case .address: .green
        case .backswing, .top, .downswing: .yellow
        default: .secondary
        }
    }

    // 3:1 full / 2:1 putt, green near it
    private func tempoColor(_ r: Double, goal: Double) -> Color {
        switch abs(r - goal) {
        case ..<0.4: .green
        case ..<0.9: .yellow
        default: .orange
        }
    }

    private var startView: some View {
        VStack(spacing: 10) {
            Image(systemName: "figure.golf")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Button("Start Session") {
                Task { await workout.start() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(workout.state == .starting)

            Picker("Hand", selection: $handedness) {
                Text("Righty").tag(Handedness.right)
                Text("Lefty").tag(Handedness.left)
            }

            if case .failed(let msg) = workout.state {
                Text(msg).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    // manual 3s capture, still handy for recording non-swings
    private var recordButton: some View {
        Button {
            Task {
                if let rec = await capture.record() {
                    connectivity.send(rec)
                }
            }
        } label: {
            Text(buttonText)
                .frame(maxWidth: .infinity)
        }
        .tint(buttonColor)
        .disabled(capture.isBusy)
    }

    private var buttonText: String {
        switch capture.recordState {
        case .ready, .saved, .failed: "Record 3s"
        case .countdown(let n): "\(n)…"
        case .recording: "Swing!"
        case .saving: "Saving"
        }
    }

    private var buttonColor: Color {
        switch capture.recordState {
        case .recording: .red
        case .countdown: .yellow
        default: .gray
        }
    }

    private var status: some View {
        VStack(spacing: 2) {
            if case .failed(let msg) = capture.recordState {
                Text(msg).foregroundStyle(.red)
            }
            Text("\(capture.swingCount) swings · \(capture.source) \(Int(capture.accelHz))/\(Int(capture.motionHz)) Hz")
            Text(connectivity.pendingTransfers > 0 ? "sending \(connectivity.pendingTransfers)…" : "all sent")
            if let e = capture.errorText ?? connectivity.lastError {
                Text(e).foregroundStyle(.red)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
}

#Preview {
    ContentView()
        .environment(WorkoutManager())
        .environment(MotionCapture())
        .environment(WatchConnectivityManager())
}
