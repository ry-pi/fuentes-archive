import BackgroundTasks
import Foundation
import Photos
import UIKit

enum BackgroundScheduler {
    static let refreshID = "com.local.fuentesarchive.refresh"
    static let processingID = "com.local.fuentesarchive.processing"

    static func register() {
        DebugLog.event("background tasks registered")
        ContinuedDownloads.register()
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
        DebugLog.event("background \(trigger) started")
        let work = Task { @MainActor in
            await AppModel.shared.syncAndWait(trigger: trigger)
        }
        task.expirationHandler = {
            DebugLog.event("background \(trigger) expired")
            work.cancel()
        }
        Task {
            _ = await work.value
            DebugLog.event("background \(trigger) finished cancelled=\(work.isCancelled)")
            task.setTaskCompleted(success: !work.isCancelled)
            scheduleAll()
        }
    }

    private static func earliest() -> Date {
        let minutes = max(15, LibraryStore.shared.snapshot().settings.checkIntervalMinutes)
        return Date(timeIntervalSinceNow: TimeInterval(minutes * 60))
    }

    private static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = earliest()
        do {
            try BGTaskScheduler.shared.submit(request)
            DebugLog.detail("scheduled background refresh")
        } catch {
            DebugLog.event("background refresh schedule failed \(error.localizedDescription)")
        }
    }

    private static func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: processingID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = earliest()
        do {
            try BGTaskScheduler.shared.submit(request)
            DebugLog.detail("scheduled background processing")
        } catch {
            DebugLog.event("background processing schedule failed \(error.localizedDescription)")
        }
    }
}

enum ContinuedDownloads {
    static let identifier = "com.local.fuentesarchive.continued"

    static func register() {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            ContinuedRuntime.register()
        }
        #else
        DebugLog.event("continued processing needs the iOS 26 SDK; background URLSession and refresh stay in use")
        #endif
    }

    static func update(title: String, completed: Int64, total: Int64) {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            ContinuedRuntime.update(title: title, completed: completed, total: total)
        }
        #endif
    }

    static func finish() {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            ContinuedRuntime.finish()
        }
        #endif
    }
}

#if compiler(>=6.2)
@available(iOS 26.0, *)
private enum ContinuedRuntime {
    static var task: BGContinuedProcessingTask?
    static var submitted = false

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: ContinuedDownloads.identifier, using: nil) { incoming in
            guard let continued = incoming as? BGContinuedProcessingTask else {
                incoming.setTaskCompleted(success: false)
                return
            }
            task = continued
            continued.expirationHandler = {
                DebugLog.event("continued processing expired")
                continued.setTaskCompleted(success: false)
                task = nil
                submitted = false
            }
            DebugLog.event("continued processing started")
            Task { @MainActor in
                AppModel.shared.refreshContinuedProgress()
            }
        }
    }

    static func update(title: String, completed: Int64, total: Int64) {
        if task == nil && !submitted { submit(title: title) }
        task?.title = title
        task?.subtitle = "Fuentes Archive"
        task?.progress.totalUnitCount = max(total, 1)
        task?.progress.completedUnitCount = min(max(completed, 0), max(total, 1))
    }

    static func finish() {
        guard task != nil || submitted else { return }
        task?.setTaskCompleted(success: true)
        task = nil
        submitted = false
        DebugLog.event("continued processing finished")
    }

    private static func submit(title: String) {
        let request = BGContinuedProcessingTaskRequest(
            identifier: ContinuedDownloads.identifier,
            title: title,
            subtitle: "Fuentes Archive"
        )
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            submitted = true
            DebugLog.event("continued processing submitted \(title)")
        } catch {
            DebugLog.event("continued processing submit failed \(error.localizedDescription)")
        }
    }
}
#endif

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
