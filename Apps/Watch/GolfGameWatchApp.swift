import SwiftUI

@main
struct GolfGameWatchApp: App {
    @State private var workout = WorkoutManager()
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
