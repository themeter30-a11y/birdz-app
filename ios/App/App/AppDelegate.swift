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

        // Set notification delegate early so iOS always has a delegate for local notifications
        UNUserNotificationCenter.current().delegate = self

        // Request notification permissions early
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error {
                print("BirdzBG: Auth error: \(error.localizedDescription)")
            }
            print("BirdzBG: Notification permission granted=\(granted)")
        }

        // Restore badge from saved value
        let savedBadge = UserDefaults.standard.integer(forKey: StorageKeys.unreadBadge)
        UIApplication.shared.applicationIconBadgeNumber = savedBadge

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

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {}
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

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
            guard changed else {
                UserDefaults.standard.set(newHash, forKey: StorageKeys.lastBackgroundContentHash)
                completion(true, false)
                return
            }

            guard !self.shouldSuppressZeroCommentNotification(in: html, unreadBadge: unreadBadge) else {
                print("BirdzBG: Skipping notification – 0 nových komentárov")
                UserDefaults.standard.set(newHash, forKey: StorageKeys.lastBackgroundContentHash)
                completion(true, false)
                return
            }

            let snippet = self.extractSnippet(from: html)
            self.sendBackgroundNotification(body: snippet, badge: unreadBadge) { scheduled in
                if scheduled {
                    UserDefaults.standard.set(newHash, forKey: StorageKeys.lastBackgroundContentHash)
                } else {
                    print("BirdzBG: Notification scheduling failed, keeping hash unsynced for retry")
                }

                completion(true, true)
            }
        }.resume()
    }

    // Removed clearStaleBirdzNotifications — it was wiping badge and delivered notifications on every launch

    private func simpleHash(_ str: String) -> String {
        var hash = 0
        for ch in str.unicodeScalars {
            hash = ((hash &<< 5) &- hash) &+ Int(ch.value)
        }
        return String(hash, radix: 36)
    }

    private func normalizedText(from html: String) -> String {
        html
            .replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractSnippet(from html: String) -> String {
        let stripped = normalizedText(from: html)
        let patterns = [
            #"(\d{1,3}\s+nov.{0,24}?koment.{0,32}?pod\s+(?:statusom|statuse|blogom|blogu|fórom|forum|obrázkom|obrazkom|albumom)\s+.{0,220})"#,
            #"([A-Za-zÁ-ž0-9_\-]{2,40}\s+ťa\s+označil.{0,220})"#,
            #"([A-Za-zÁ-ž0-9_\-]{2,40}\s+(?:reagoval|komentoval|okomentoval|sleduje|poslal|pridal).{0,220})"#
        ]

        for pattern in patterns {
            if let match = firstStringMatch(in: stripped, pattern: pattern),
               !match.lowercased().contains("tajné správy"),
               !match.lowercased().contains("tajne spravy") {
                return match
            }
        }

        return "Máš novú aktivitu v reakciách"
    }

    private func shouldSuppressZeroCommentNotification(in html: String, unreadBadge: Int) -> Bool {
        guard unreadBadge == 0 else { return false }

        let normalized = normalizedText(from: html).lowercased()

        return normalized.contains("0 nových komment") ||
            normalized.contains("0 nových koment") ||
            normalized.contains("0 novych koment")
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

        let stripped = normalizedText(from: html)

        let textPatterns = [
            #"(\d{1,3})\s+nov.{0,24}(?:koment|reakci|upozor|sprav|správ)"#,
            #"neprečítan[ée]\s+(\d{1,3})"#
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

    private func firstStringMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        return String(text[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func sendBackgroundNotification(body: String, badge: Int, completion: @escaping (Bool) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = "Birdz"
        content.body = body
        content.sound = .default
        content.badge = NSNumber(value: max(badge, 0))
        content.userInfo = ["deepLink": "https://www.birdz.sk/reakcie/"]
        content.threadIdentifier = "birdz-reakcie"
        content.categoryIdentifier = "BIRDZ_REAKCIA"

        if #available(iOS 15.0, *) {
            content.interruptionLevel = .active
            content.relevanceScore = 1.0
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1.0, repeats: false)
        let request = UNNotificationRequest(identifier: "birdz-bg-\(UUID().uuidString)", content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("BirdzBG: Notification error: \(error.localizedDescription)")
                completion(false)
                return
            }

            print("BirdzBG: ✅ Notification scheduled successfully id=\(request.identifier) body=\(body)")
            completion(true)
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        print("BirdzBG: willPresent called for \(notification.request.identifier)")
        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
