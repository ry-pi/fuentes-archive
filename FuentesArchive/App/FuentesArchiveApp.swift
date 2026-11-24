import SwiftUI

@main
struct FuentesArchiveApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onAppear { model.syncIfStale() }
                .onOpenURL { url in model.open(url) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.syncIfStale()
                WidgetBridge.shared.syncActivity(force: true)
                BackgroundScheduler.scheduleAll()
            }
        }
    }
}
