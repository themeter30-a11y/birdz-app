import UIKit
import Capacitor
import BackgroundTasks

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    static let bgTaskIdentifier = "app.lovable.birdz.reakcie.refresh"

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Register background refresh task
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppDelegate.bgTaskIdentifier, using: nil) { task in
            self.handleBackgroundRefresh(task: task as! BGAppRefreshTask)
        }
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {}

    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduleBackgroundRefresh()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {}

    func applicationDidBecomeActive(_ application: UIApplication) {}

    func applicationWillTerminate(_ application: UIApplication) {}

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }

    // MARK: - Background Refresh

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: AppDelegate.bgTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60) // 5 minutes minimum
        do {
            try BGTaskScheduler.shared.submit(request)
            print("BirdzBG: Scheduled background refresh")
        } catch {
            print("BirdzBG: Failed to schedule: \(error.localizedDescription)")
        }
    }

    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        // Schedule the next refresh immediately
        scheduleBackgroundRefresh()

        // Create a URL session task to fetch /reakcie/
        let url = URL(string: "https://www.birdz.sk/reakcie/")!
        let session = URLSession(configuration: .default)

        // Share cookies from WKWebView via HTTPCookieStorage
        let dataTask = session.dataTask(with: url) { [weak self] data, response, error in
            guard let data = data, error == nil else {
                task.setTaskCompleted(success: false)
                return
            }

            let html = String(data: data, encoding: .utf8) ?? ""
            let hash = self?.simpleHash(html) ?? ""
            let savedHash = UserDefaults.standard.string(forKey: "birdz_last_bg_hash") ?? ""

            if !savedHash.isEmpty && hash != savedHash {
                // Content changed — send notification
                let snippet = self?.extractSnippet(from: html) ?? "Máš novú aktivitu"
                self?.sendBackgroundNotification(body: snippet)

                // Update badge
                let currentBadge = UserDefaults.standard.integer(forKey: "birdz_pending_badge")
                let newBadge = currentBadge + 1
                UserDefaults.standard.set(newBadge, forKey: "birdz_pending_badge")
                DispatchQueue.main.async {
                    UIApplication.shared.applicationIconBadgeNumber = newBadge
                }
            }

            UserDefaults.standard.set(hash, forKey: "birdz_last_bg_hash")
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            dataTask.cancel()
        }

        dataTask.resume()
    }

    private func simpleHash(_ str: String) -> String {
        var hash: Int = 0
        for ch in str.unicodeScalars {
            hash = ((hash &<< 5) &- hash) &+ Int(ch.value)
        }
        return String(hash, radix: 36)
    }

    private func extractSnippet(from html: String) -> String {
        // Try to extract meaningful text from the HTML
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Look for reaction-related keywords
        let keywords = ["reagoval", "komentoval", "okomentoval", "označil", "sleduje", "správ", "blog", "fotk", "status"]
        for keyword in keywords {
            if let range = stripped.range(of: keyword, options: .caseInsensitive) {
                let start = stripped.index(range.lowerBound, offsetBy: -50, limitedBy: stripped.startIndex) ?? stripped.startIndex
                let end = stripped.index(range.upperBound, offsetBy: 100, limitedBy: stripped.endIndex) ?? stripped.endIndex
                return String(stripped[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return "Máš novú aktivitu v reakciách"
    }

    private func sendBackgroundNotification(body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Birdz"
        content.body = body
        content.sound = .default
        content.badge = NSNumber(value: UserDefaults.standard.integer(forKey: "birdz_pending_badge"))
        content.userInfo = ["deepLink": "https://www.birdz.sk/reakcie/"]
        content.threadIdentifier = "birdz-reakcie"

        // Attach icon
        if let iconURL = Bundle.main.url(forResource: "birdz_notification", withExtension: "png") {
            do {
                let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                let tmpFile = tmpDir.appendingPathComponent("birdz_notification.png")
                try FileManager.default.copyItem(at: iconURL, to: tmpFile)
                let attachment = try UNNotificationAttachment(identifier: "birdz-icon", url: tmpFile, options: nil)
                content.attachments = [attachment]
            } catch {}
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        let request = UNNotificationRequest(identifier: "birdz-bg-\(UUID().uuidString)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
