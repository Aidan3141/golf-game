import SwiftUI

@main
struct GolfGamePhoneApp: App {
    @State private var connectivity = PhoneConnectivity()
    @State private var store = RecordingStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(connectivity)
                .environment(store)
                .onAppear {
                    store.reload()
                    connectivity.onReceive = { [store] in store.reload() }
                }
        }
    }
}
