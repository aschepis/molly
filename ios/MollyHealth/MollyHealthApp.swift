import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let env = AppEnvironment.shared
        env.background.registerRefreshTask()
        let settings = env.settingsStore.loadSettings()
        // Observers must exist at every launch, including the ones HealthKit starts in the background.
        if settings.hasRequestedAuthorization {
            env.background.startObservers(enabled: settings.enabledInCatalogOrder)
            env.background.scheduleRefresh()
        }
        env.log.append("launched")
        return true
    }
}

@main
struct MollyHealthApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                SettingsView()
            }
            .environmentObject(model)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.reloadState() }
            }
        }
    }
}
