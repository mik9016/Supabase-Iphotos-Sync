import UIKit
import BackgroundTasks

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        registerBackgroundTasks()
        return true
    }

    // Handle background URL session completion
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // Store completion handler for background upload manager
        BackgroundUploadManager.shared.backgroundCompletionHandler = completionHandler
    }

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Constants.BackgroundTasks.refreshIdentifier,
            using: nil
        ) { task in
            self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Constants.BackgroundTasks.processingIdentifier,
            using: nil
        ) { task in
            self.handleBackgroundProcessing(task: task as! BGProcessingTask)
        }
    }

    func scheduleBackgroundTasks() {
        scheduleAppRefresh()
        scheduleBackgroundProcessing()
    }

    private func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Constants.BackgroundTasks.refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Constants.BackgroundTasks.minimumBackgroundFetchInterval)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Could not schedule app refresh: \(error)")
        }
    }

    private func scheduleBackgroundProcessing() {
        let request = BGProcessingTaskRequest(identifier: Constants.BackgroundTasks.processingIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Could not schedule background processing: \(error)")
        }
    }

    private func handleAppRefresh(task: BGAppRefreshTask) {
        scheduleAppRefresh()

        let settings = AppSettings.shared

        guard settings.autoSyncEnabled && settings.isConfigured else {
            task.setTaskCompleted(success: true)
            return
        }

        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        Task {
            let syncManager = SyncManager.shared

            if syncManager.canSync {
                await MainActor.run {
                    syncManager.startSync()
                }
            }

            task.setTaskCompleted(success: true)
        }
    }

    private func handleBackgroundProcessing(task: BGProcessingTask) {
        scheduleBackgroundProcessing()

        let settings = AppSettings.shared

        guard settings.autoSyncEnabled && settings.isConfigured else {
            task.setTaskCompleted(success: true)
            return
        }

        task.expirationHandler = {
            Task { @MainActor in
                SyncManager.shared.cancelSync()
            }
            task.setTaskCompleted(success: false)
        }

        Task {
            let syncManager = SyncManager.shared

            if syncManager.canSync {
                await MainActor.run {
                    syncManager.startSync()
                }

                while syncManager.isSyncing {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }

            task.setTaskCompleted(success: true)
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        let settings = AppSettings.shared
        if settings.autoSyncEnabled {
            scheduleBackgroundTasks()
        }
    }
}
