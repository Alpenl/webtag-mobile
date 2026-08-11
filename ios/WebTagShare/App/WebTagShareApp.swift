import SwiftUI
import UIKit

@main
struct WebTagShareApp: App {
    @UIApplicationDelegateAdaptor(WebTagShareAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class WebTagShareAppDelegate: NSObject, UIApplicationDelegate {
    private let repository: AppGroupQueueRepository?
    private let coordinator: ShareSubmissionCoordinator?
    private let wakeScheduler: InProcessQueueWakeScheduler

    override init() {
        let wakeScheduler = InProcessQueueWakeScheduler()
        let repository = try? AppGroupQueueRepository()
        self.repository = repository
        self.wakeScheduler = wakeScheduler
        self.coordinator = repository.map { ShareSubmissionCoordinator(repository: $0, wakeScheduler: wakeScheduler) }
        super.init()
        wakeScheduler.setOnWake { [weak self] in self?.reconcileAndDrain() }
        BackgroundUploadSessionController.shared.taskCompletionHandler = { [weak self] result in
            await self?.handleBackgroundCompletion(result)
        }
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        repairActiveIdentity()
        reconcileAndDrain()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        reconcileAndDrain()
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        BackgroundUploadSessionController.shared.handleEvents(identifier: identifier, completionHandler: completionHandler)
    }

    private func reconcileAndDrain() {
        guard let coordinator, let repository else { return }
        Task {
            let active = await BackgroundUploadSessionController.shared.reconcile(
                repository: repository,
                now: Date()
            )
            await coordinator.reconcileAndDrain(excluding: active)
        }
    }

    private func repairActiveIdentity() {
        guard let repository else { return }
        do {
            guard let stored = try KeychainCredentialStore().loadConfig() else { return }
            if try repository.activeSessionIdentity() != stored.identity {
                try repository.activate(session: stored.identity)
            }
        } catch {
            // A mismatched or unreadable credential is intentionally left unusable.
        }
    }

    private func handleBackgroundCompletion(_ result: BackgroundUploadResult) async {
        await coordinator?.handleBackgroundCompletion(result)
    }
}
