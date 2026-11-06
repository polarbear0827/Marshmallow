import AppKit
import UserNotifications

/// Progress sink for the job a task is running (set via `JobContext.$current`).
final class JobContext: @unchecked Sendable {
    @TaskLocal static var current: JobContext?
    private let onProgress: @Sendable (Double) -> Void
    init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }
    func report(_ p: Double) { onProgress(p) }
}

/// One running wheel item.
final class Job: Identifiable, ObservableObject {
    let id = UUID()
    let title: String            // e.g. "MP4"
    let subject: String          // e.g. "trip.mov" or "3 個檔案"
    @Published var progress: Double?
    var task: Task<Void, Never>?
    /// While true the wheel shows this job's result; otherwise a notification is sent.
    var attachedToWheel = true

    init(title: String, subject: String) {
        self.title = title
        self.subject = subject
    }

    func cancel() { task?.cancel() }
}

/// Keeps track of running jobs for the menu bar and sends completion notifications.
final class JobCenter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = JobCenter()
    @Published private(set) var jobs: [Job] = []
    /// Called whenever the list or any progress changes (menu bar refresh).
    var onChange: (() -> Void)?

    /// Starts `item` on `files`. `finish` runs on the main thread with the result.
    @discardableResult
    func start(_ item: WheelItem, files: [URL], finish: @escaping (Job, Result<ItemResult, Error>) -> Void) -> Job {
        let subject = files.count > 1 ? "\(files.count) 個檔案" : (files.first?.lastPathComponent ?? "")
        let job = Job(title: item.title, subject: subject)
        let ctx = JobContext { [weak self, weak job] p in
            DispatchQueue.main.async {
                guard let job else { return }
                // Avoid flooding the UI: only publish visible changes.
                if job.progress == nil || abs((job.progress ?? 0) - p) >= 0.01 || p >= 1 {
                    job.progress = p
                    self?.onChange?()
                }
            }
        }
        job.task = Task.detached(priority: .userInitiated) {
            let result: Result<ItemResult, Error>
            do {
                let r = try await JobContext.$current.withValue(ctx) { try await item.run(files) }
                try Task.checkCancellation()
                result = .success(r)
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                self.jobs.removeAll { $0 === job }
                self.onChange?()
                finish(job, result)
            }
        }
        jobs.append(job)
        onChange?()
        return job
    }

    func cancelAll() { jobs.forEach { $0.cancel() } }

    /// Average progress of running jobs (nil when unknown).
    var overallProgress: Double? {
        let known = jobs.compactMap(\.progress)
        guard !known.isEmpty else { return nil }
        return known.reduce(0, +) / Double(known.count)
    }

    // MARK: Notifications

    /// UNUserNotificationCenter only works inside a real .app bundle.
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    func setUpNotifications() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func requestNotificationPermission(_ done: ((Bool) -> Void)? = nil) {
        guard canNotify else { done?(false); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            DispatchQueue.main.async { done?(ok) }
        }
    }

    /// Posts a banner for a job that finished in the background.
    func notify(_ job: Job, _ result: Result<ItemResult, Error>) {
        let content = UNMutableNotificationContent()
        switch result {
        case .success(.files(let urls)):
            content.title = "✅ \(job.title) 完成"
            content.body = urls.count > 1 ? "\(urls.count) 個檔案" : (urls.first?.lastPathComponent ?? job.subject)
            content.userInfo = ["paths": urls.map(\.path)]
        case .success(.message(let msg)):
            content.title = "✅ \(job.title) 完成"
            content.body = msg
        case .failure(let error) where error is CancellationError:
            return
        case .failure(let error):
            content.title = "❌ \(job.title) 失敗"
            content.body = "\(job.subject)：\(error.localizedDescription)"
        }
        if Settings.shared.playSound { content.sound = .default }
        guard canNotify else { print("NOTIFY: \(content.title) — \(content.body)"); return }
        let req = UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil)
        requestNotificationPermission { _ in UNUserNotificationCenter.current().add(req) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let paths = response.notification.request.content.userInfo["paths"] as? [String], !paths.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
        }
        completionHandler()
    }
}
