import SwiftUI
import SwingKit

struct ContentView: View {
    @Environment(WorkoutManager.self) private var workout
    @Environment(MotionCapture.self) private var capture
    @Environment(WatchConnectivityManager.self) private var connectivity
    @AppStorage("handedness") private var handedness = Handedness.right

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if workout.isRunning {
                    recordButton
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
        .onChange(of: workout.isRunning) { _, running in
            if running { capture.startStreaming() } else { capture.stopStreaming() }
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

    private var recordButton: some View {
        Button {
            Task {
                if let rec = await capture.record(handedness: handedness) {
                    connectivity.send(rec)
                }
            }
        } label: {
            ZStack {
                Circle().fill(buttonColor)
                Text(buttonText)
                    .font(.system(size: buttonText.count <= 2 ? 44 : 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
            }
            .frame(width: 120, height: 120)
        }
        .buttonStyle(.plain)
        .disabled(capture.isBusy)
    }

    private var buttonText: String {
        switch capture.recordState {
        case .ready, .saved, .failed: "Record"
        case .countdown(let n): "\(n)"
        case .recording: "Swing!"
        case .saving: "Saving"
        }
    }

    private var buttonColor: Color {
        switch capture.recordState {
        case .recording: .red
        case .countdown: .yellow
        case .saving: .gray
        default: .green
        }
    }

    private var status: some View {
        VStack(spacing: 2) {
            if case .failed(let msg) = capture.recordState {
                Text(msg).foregroundStyle(.red)
            }
            if let r = capture.lastRecording {
                Text("last: \(r.accel.count) accel · \(r.motion.count) motion")
            }
            Text("\(capture.source) \(Int(capture.accelHz))/\(Int(capture.motionHz)) Hz")
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
