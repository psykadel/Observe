import SwiftUI

@main
struct ObserveApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var preferences: ObservePreferences
    @StateObject private var store: HomeKitCameraStore

    init() {
        let preferences = ObservePreferences()
        _preferences = StateObject(wrappedValue: preferences)
        _store = StateObject(wrappedValue: HomeKitCameraStore(preferences: preferences))
    }

    var body: some Scene {
        WindowGroup {
            CameraWallView(store: store, preferences: preferences)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    store.setAppActive(phase == .active)
                }
        }
    }
}
