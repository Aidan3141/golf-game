import Foundation
import HealthKit
import Observation

// golf workout session, only used to keep the app awake + get fast sensors. nothing saved to health
@MainActor
@Observable
final class WorkoutManager: NSObject {
    // one instance, the app delegate needs it for workout recovery
    static let shared = WorkoutManager()

    enum State: Equatable {
        case idle, starting, running, failed(String)
    }

    private(set) var state = State.idle
    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?

    var isRunning: Bool { state == .running }

    func start() async {
        guard state != .running, state != .starting else { return }
        state = .starting
        do {
            // workout type share perm is needed to run a session even tho we never save one
            try await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [])
            let config = HKWorkoutConfiguration()
            config.activityType = .golf
            config.locationType = .outdoor
            let s = try HKWorkoutSession(healthStore: store, configuration: config)
            s.delegate = self
            session = s
            s.startActivity(with: .now)
            state = .running
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // watchos relaunches us after a crash/kill while a workout is live. grab that session
    // instead of starting a second one
    func recover() {
        // healthkit calls back on its own queue, keep the closure off the main actor
        store.recoverActiveWorkoutSession { @Sendable session, _ in
            guard let session else { return }
            Task { @MainActor in
                session.delegate = self
                self.session = session
                self.state = .running
            }
        }
    }

    func stop() {
        session?.end()
        session = nil
        state = .idle
    }
}

extension WorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        if toState == .ended || toState == .stopped {
            Task { @MainActor in
                if self.state == .running { self.state = .idle }
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        let msg = error.localizedDescription
        Task { @MainActor in self.state = .failed(msg) }
    }
}
