import Foundation
import UIKit
import UserNotifications
import WebKit

final class BirdzNotificationMonitor: NSObject {
    static let shared = BirdzNotificationMonitor()

    private let messageHandlerName = "birdzNotificationMonitor"

    private weak var webView: WKWebView?
    private var timer: Timer?
    private var lastBadgeCount: Int = -1
    private var lastNotificationSignatures = Set<String>()

    func startMonitoring(webView: WKWebView) {
        self.webView = webView

        DispatchQueue.main.async { [weak self] in
            self?.applySafeAreaInset()
        }

        configureMessageBridge(for: webView)
        requestNotificationPermissionIfNeeded()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.runMonitor()
        }

        runMonitor()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.applySafeAreaInset()
            self?.runMonitor()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil

        webView?.configuration.userContentController.removeScriptMessageHandler(forName: messageHandlerName)
        webView = nil
    }

    private func configureMessageBridge(for webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: messageHandlerName)
        controller.add(self, name: messageHandlerName)
    }

    private func requestNotificationPermissionIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }

            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                if granted {
                    print("BirdzMonitor: Notification permission granted")
                } else {
                    print("BirdzMonitor: Notification permission denied: \(String(describing: error))")
                }
            }
        }
    }

    private func runMonitor() {
        guard let webView else { return }

        DispatchQueue.main.async { [weak self] in
            self?.applySafeAreaInset()
            webView.evaluateJavaScript(BirdzMonitorInjectedScript.source) { _, error in
                if let error {
                    print("BirdzMonitor: JS inject error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func applySafeAreaInset() {
        guard let webView else { return }

        let topInset = webView.safeAreaInsets.top
        guard topInset > 0 else { return }

        webView.scrollView.contentInsetAdjustmentBehavior = .never

        var contentInset = webView.scrollView.contentInset
        if abs(contentInset.top - topInset) > 0.5 {
            contentInset.top = topInset
            webView.scrollView.contentInset = contentInset
        }

        var indicatorInset = webView.scrollView.scrollIndicatorInsets
        if abs(indicatorInset.top - topInset) > 0.5 {
            indicatorInset.top = topInset
            webView.scrollView.scrollIndicatorInsets = indicatorInset
        }

        if webView.scrollView.contentOffset.y > -topInset {
            webView.scrollView.setContentOffset(CGPoint(x: 0, y: -topInset), animated: false)
        }
    }

    private func processPayload(_ payload: [String: Any]) {
        let totalCount = payload["totalCount"] as? Int ?? 0
        let details = payload["details"] as? [[String: Any]] ?? []

        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = totalCount
        }

        print("BirdzMonitor: Badge = \(totalCount), previous = \(lastBadgeCount), details = \(details.count)")

        guard lastBadgeCount >= 0 else {
            lastBadgeCount = totalCount
            lastNotificationSignatures = Set(details.map { signature(for: $0) })
            return
        }

        if totalCount > lastBadgeCount {
            let newNotifications = totalCount - lastBadgeCount
            let unseenDetails = details.filter { !lastNotificationSignatures.contains(signature(for: $0)) }

            if !unseenDetails.isEmpty {
                for detail in unseenDetails.prefix(max(newNotifications, 1)) {
                    sendDetailedNotification(detail, badge: totalCount)
                }
            } else {
                sendNotification(
                    title: "Birdz",
                    body: newNotifications == 1
                        ? "Máš novú notifikáciu"
                        : "Máš \(newNotifications) nových notifikácií",
                    badge: totalCount
                )
            }
        }

        lastBadgeCount = totalCount
        lastNotificationSignatures = Set(details.map { signature(for: $0) })
    }

    private func signature(for detail: [String: Any]) -> String {
        let type = detail["type"] as? String ?? ""
        let sender = detail["sender"] as? String ?? ""
        let preview = detail["preview"] as? String ?? ""

        return [type, sender, preview].joined(separator: "|")
    }

    private func sendDetailedNotification(_ detail: [String: Any], badge: Int) {
        let type = detail["type"] as? String ?? "Upozornenie"
        let sender = detail["sender"] as? String ?? ""
        let preview = detail["preview"] as? String ?? ""

        let body: String
        if !sender.isEmpty && !preview.isEmpty {
            body = "\(sender): \(preview)"
        } else if !preview.isEmpty {
            body = preview
        } else if !sender.isEmpty {
            body = "Od: \(sender)"
        } else {
            body = "Máš novú notifikáciu"
        }

        sendNotification(
            title: "Birdz – \(type)",
            body: body,
            badge: badge
        )
    }

    private func sendNotification(title: String, body: String, badge: Int) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.badge = NSNumber(value: badge)

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "birdz-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("BirdzMonitor: Notification error: \(error.localizedDescription)")
            } else {
                print("BirdzMonitor: Sent – \(title): \(body)")
            }
        }
    }
}

extension BirdzNotificationMonitor: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == messageHandlerName,
              let payload = message.body as? [String: Any] else {
            return
        }

        processPayload(payload)
    }
}
