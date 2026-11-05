import SwiftUI
import SwingKit

@main
struct GolfGamePhoneApp: App {
    @State private var connectivity = PhoneConnectivity()
    @State private var store = RecordingStore()
    @State private var sender = NetworkSwingSender()
    @State private var feed = SwingFeed()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(connectivity)
                .environment(store)
                .environment(sender)
                .environment(feed)
                .onAppear {
                    store.reload()
                    sender.start()
                    // relay only works w/ the app open, so dont let the screen lock
                    UIApplication.shared.isIdleTimerDisabled = true
                    connectivity.onReceive = { [store] in store.reload() }
                    connectivity.onSwing = { [sender, feed] swing, sentAt in
                        sender.send(swing)
                        feed.add(swing, watchLatency: Date.now.timeIntervalSince(sentAt))
                    }
                }
        }
    }
}
