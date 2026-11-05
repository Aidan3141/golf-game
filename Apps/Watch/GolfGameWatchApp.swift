import SwiftUI
import WatchKit

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handleActiveWorkoutRecovery() {
        Task { @MainActor in WorkoutManager.shared.recover() }
    }
}

@main
struct GolfGameWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: WatchAppDelegate
    @State private var workout = WorkoutManager.shared
    @State private var capture = MotionCapture()
    @State private var connectivity = WatchConnectivityManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(workout)
                .environment(capture)
                .environment(connectivity)
        }
    }
}
