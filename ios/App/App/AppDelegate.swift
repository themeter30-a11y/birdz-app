import UIKit
import Capacitor
import BackgroundTasks
import UserNotifications

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    private enum StorageKeys {
        static let lastBackgroundContentHash = "birdz_last_background_content_hash"
        static let unreadBadge = "birdz_unread_badge"
    }

    var window: UIWindow?
    static let bgTaskIdentifier = "app.lovable.birdz.reakcie.refresh"

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        application.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)

        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppDelegate.bgTaskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleBackgroundRefresh(task: refreshTask)
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

    func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        performBackgroundRefresh { success, changed in
            if !success {
                completionHandler(.failed)
            } else {
                completionHandler(changed ? .newData : .noData)
            }
        }
    }

    // MARK: - Background Refresh

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: AppDelegate.bgTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            print("BirdzBG: Scheduled background refresh")
        } catch {
            print("BirdzBG: Failed to schedule: \(error.localizedDescription)")
        }
    }

    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()

        performBackgroundRefresh { success, _ in
            task.setTaskCompleted(success: success)
        }

        task.expirationHandler = {
            print("BirdzBG: Background task expired")
        }
    }

    private func performBackgroundRefresh(completion: @escaping (Bool, Bool) -> Void) {
        guard let url = URL(string: "https://www.birdz.sk/reakcie/") else {
            completion(false, false)
            return
        }

        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let session = URLSession(configuration: .ephemeral)

        session.dataTask(with: request) { [weak self] data, _, error in
            guard let self, let data, error == nil else {
                completion(false, false)
                return
            }

            let html = String(data: data, encoding: .utf8) ?? ""
            let newHash = self.simpleHash(html)
            let savedHash = UserDefaults.standard.string(forKey: StorageKeys.lastBackgroundContentHash) ?? ""
            let unreadBadge = self.extractUnreadBadge(from: html) ?? UserDefaults.standard.integer(forKey: StorageKeys.unreadBadge)

            UserDefaults.standard.set(unreadBadge, forKey: StorageKeys.unreadBadge)
            DispatchQueue.main.async {
                UIApplication.shared.applicationIconBadgeNumber = unreadBadge
            }

            let changed = !savedHash.isEmpty && newHash != savedHash
            if changed {
                let snippet = self.extractSnippet(from: html)
                self.sendBackgroundNotification(body: snippet, badge: unreadBadge)
            }

            UserDefaults.standard.set(newHash, forKey: StorageKeys.lastBackgroundContentHash)
            completion(true, changed)
        }.resume()
    }

    private func simpleHash(_ str: String) -> String {
        var hash = 0
        for ch in str.unicodeScalars {
            hash = ((hash &<< 5) &- hash) &+ Int(ch.value)
        }
        return String(hash, radix: 36)
    }

    private func extractSnippet(from html: String) -> String {
        let stripped = html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let keywords = ["reagoval", "komentoval", "okomentoval", "označil", "oznacil", "sleduje", "správ", "sprav", "blog", "fotk", "status", "forum", "fór"]
        for keyword in keywords {
            if let range = stripped.range(of: keyword, options: .caseInsensitive) {
                let start = stripped.index(range.lowerBound, offsetBy: -60, limitedBy: stripped.startIndex) ?? stripped.startIndex
                let end = stripped.index(range.upperBound, offsetBy: 140, limitedBy: stripped.endIndex) ?? stripped.endIndex
                return String(stripped[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return "Máš novú aktivitu v reakciách"
    }

    private func extractUnreadBadge(from html: String) -> Int? {
        let htmlPatterns = [
            #"class\s*=\s*"[^"]*(?:badge|count|notif|num)[^"]*"[^>]*>\s*(\d{1,3})\s*<"#
        ]

        for pattern in htmlPatterns {
            if let value = firstMatch(in: html, pattern: pattern) {
                return value
            }
        }

        let stripped = html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let textPatterns = [
            #"(\d{1,3})\s+nov.{0,24}(?:koment|reakci|upozor|sprav|správ)"#
        ]

        for pattern in textPatterns {
            if let value = firstMatch(in: stripped, pattern: pattern) {
                return value
            }
        }

        return nil
    }

    private func firstMatch(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        return Int(text[valueRange])
    }

    private func sendBackgroundNotification(body: String, badge: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Birdz"
        content.body = body
        content.sound = .default
        content.badge = NSNumber(value: max(badge, 0))
        content.userInfo = ["deepLink": "https://www.birdz.sk/reakcie/"]
        content.threadIdentifier = "birdz-reakcie"

        if let iconURL = Bundle.main.url(forResource: "birdz_notification", withExtension: "png") {
            do {
                let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                let tmpFile = tmpDir.appendingPathComponent("birdz_notification.png")
                try FileManager.default.copyItem(at: iconURL, to: tmpFile)
                let attachment = try UNNotificationAttachment(identifier: "birdz-icon", url: tmpFile, options: nil)
                content.attachments = [attachment]
            } catch {
                print("BirdzBG: Attachment error: \(error.localizedDescription)")
            }
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        let request = UNNotificationRequest(identifier: "birdz-bg-\(UUID().uuidString)", content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("BirdzBG: Notification error: \(error.localizedDescription)")
            }
        }
    }
}
