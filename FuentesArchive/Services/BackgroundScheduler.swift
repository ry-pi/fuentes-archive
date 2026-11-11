import BackgroundTasks
import Foundation
import Photos
import UIKit

enum BackgroundScheduler {
    static let refreshID = "com.local.fuentesarchive.refresh"
    static let processingID = "com.local.fuentesarchive.processing"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            handle(task, trigger: "background-refresh")
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            handle(task, trigger: "background-processing")
        }
    }

    static func scheduleAll() {
        scheduleRefresh()
        scheduleProcessing()
    }

    private static func handle(_ task: BGTask, trigger: String) {
        let work = Task { @MainActor in
            await AppModel.shared.syncAndWait(trigger: trigger)
        }
        task.expirationHandler = { work.cancel() }
        Task {
            _ = await work.value
            task.setTaskCompleted(success: !work.isCancelled)
            scheduleAll()
        }
    }

    private static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: processingID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

enum PhotosLibrary {
    static func addVideo(_ url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion(.failure(PhotoError.denied))
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                if let error { completion(.failure(error)) }
                else if success { completion(.success(())) }
                else { completion(.failure(PhotoError.failed)) }
            }
        }
    }

    enum PhotoError: LocalizedError {
        case denied, failed
        var errorDescription: String? {
            switch self {
            case .denied: return "Photos access was not allowed. The file is still in the Files app."
            case .failed: return "Photos could not import this file. MPEG-TS downloads stay in Files and play in the app."
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = AppModel.shared
        DownloadManager.shared.reconnect()
        BackgroundScheduler.register()
        BackgroundScheduler.scheduleAll()
        if LibraryStore.shared.snapshot().settings.notify {
            NotificationService.request()
        }
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        _ = AppModel.shared
        if identifier == DownloadManager.sessionID {
            DownloadManager.shared.reconnect()
            DownloadManager.shared.setBackgroundCompletion(completionHandler)
        } else {
            completionHandler()
        }
    }
}
