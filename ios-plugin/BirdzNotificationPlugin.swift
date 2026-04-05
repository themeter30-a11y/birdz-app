import Foundation
import UIKit
import UserNotifications
import WebKit

private enum BirdzNotificationScrapeScript {
    static let source = #"""
    (function() {
        var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.birdzNotificationMonitor;
        if (!handler) return 'birdz-handler-missing';

        function trimText(value) {
            return (value || '').replace(/\s+/g, ' ').trim();
        }

        function normalizeUrl(value) {
            try {
                return new URL(value, window.location.href).toString();
            } catch (error) {
                return null;
            }
        }

        function parseCount(text) {
            var match = trimText(text).match(/\d+/);
            return match ? parseInt(match[0], 10) : 0;
        }

        function detectType(text) {
            var value = trimText(text).toLowerCase();

            if (value.indexOf('tajn') > -1 || value.indexOf('správ') > -1 || value.indexOf('sprav') > -1 || value.indexOf('ts') > -1) {
                return 'Tajná správa';
            }

            if (value.indexOf('reakci') > -1) {
                return 'Reakcia na status';
            }

            if (value.indexOf('koment') > -1) {
                return 'Komentár';
            }

            if (value.indexOf('sleduj') > -1) {
                return 'Nový sledovateľ';
            }

            if (value.indexOf('označil') > -1 || value.indexOf('oznacil') > -1) {
                return 'Označenie';
            }

            return 'Upozornenie';
        }

        function badgeCandidates(root) {
            return root.querySelectorAll([
                '.button-more .badge',
                '.header_user_avatar .badge',
                '.header .badge',
                '.badge',
                '[class*="notif"] .badge',
                '[class*="alert"] .badge',
                '[class*="message"] .badge'
            ].join(','));
        }

        function extractTotalCount(root) {
            var badges = badgeCandidates(root);
            for (var i = 0; i < badges.length; i++) {
                var value = parseCount(badges[i].textContent);
                if (value > 0) {
                    return value;
                }
            }

            var header = root.querySelector('header, .header, #header, nav');
            if (!header) {
                return 0;
            }

            var nodes = header.querySelectorAll('span, div, a, sup, strong, b');
            for (var j = 0; j < nodes.length; j++) {
                var value = parseCount(nodes[j].textContent);
                if (value > 0 && value < 1000) {
                    return value;
                }
            }

            return 0;
        }

        function pickPreview(container) {
            var selectors = [
                '.message',
                '.preview',
                '.description',
                '.text',
                '[class*="message"]',
                '[class*="preview"]',
                '[class*="body"]',
                'p',
                'em',
                'span'
            ];

            for (var i = 0; i < selectors.length; i++) {
                var element = container.querySelector(selectors[i]);
                var text = trimText(element && element.textContent);

                if (text && !/^\d+$/.test(text)) {
                    return text.slice(0, 220);
                }
            }

            return trimText(container.textContent).slice(0, 220);
        }

        function pickSender(container) {
            var selectors = [
                '.username',
                '.user',
                '.name',
                '[class*="username"]',
                '[class*="sender"]',
                '[class*="author"]',
                'strong',
                'b',
                'a[href*="profil"]',
                'a[href*="user"]'
            ];

            for (var i = 0; i < selectors.length; i++) {
                var element = container.querySelector(selectors[i]);
                var text = trimText(element && element.textContent);

                if (text && !/^\d+$/.test(text)) {
                    return text.slice(0, 80);
                }
            }

            return '';
        }

        function extractDetails(root) {
            var containers = root.querySelectorAll([
                '.notifications-list li',
                '.notification-item',
                '[class*="notif"] li',
                '[class*="notification"] li',
                '.dropdown-menu li',
                '.menu-dropdown li',
                '.list-group-item',
                '[class*="notification"]'
            ].join(','));

            var details = [];
            var seen = {};

            for (var i = 0; i < containers.length; i++) {
                var container = containers[i];
                var fullText = trimText(container.textContent);
                if (!fullText) continue;

                var detail = {
                    type: detectType(fullText),
                    sender: pickSender(container),
                    preview: pickPreview(container),
                    count: 1
                };

                var signature = [detail.type, detail.sender, detail.preview].join('|');
                if (seen[signature]) continue;

                seen[signature] = true;
                details.push(detail);

                if (details.length >= 10) {
                    break;
                }
            }

            return details;
        }

        function collect(root, sourceUrl) {
            return {
                totalCount: extractTotalCount(root),
                details: extractDetails(root),
                sourceUrl: sourceUrl || window.location.href
            };
        }

        function candidateUrls() {
            var urls = [window.location.href];
            var links = document.querySelectorAll('a[href]');

            for (var i = 0; i < links.length; i++) {
                var href = links[i].getAttribute('href');
                var url = normalizeUrl(href);
                var text = trimText((links[i].textContent || '') + ' ' + (href || ''));

                if (!url || url.indexOf(window.location.origin) !== 0) continue;

                if (/(notifik|upozorn|sprav|message|inbox|ts)/i.test(text) || /(notifik|upozorn|sprav|message|inbox|ts)/i.test(url)) {
                    urls.push(url);
                }
            }

            return Array.from(new Set(urls)).slice(0, 4);
        }

        function betterSnapshot(current, next) {
            if (!next) return current;
            if (!current) return next;

            if ((next.totalCount || 0) > (current.totalCount || 0)) {
                return next;
            }

            if ((next.details || []).length > (current.details || []).length) {
                return next;
            }

            var nextRichness = (next.details || []).reduce(function(total, item) {
                return total + ((item.preview || '').length);
            }, 0);

            var currentRichness = (current.details || []).reduce(function(total, item) {
                return total + ((item.preview || '').length);
            }, 0);

            return nextRichness > currentRichness ? next : current;
        }

        async function fetchSnapshot(url) {
            try {
                var response = await fetch(url, {
                    method: 'GET',
                    credentials: 'include',
                    cache: 'no-store',
                    headers: {
                        'X-Requested-With': 'BirdzApp'
                    }
                });

                if (!response.ok) {
                    return null;
                }

                var html = await response.text();
                if (!html) {
                    return null;
                }

                var parser = new DOMParser();
                var doc = parser.parseFromString(html, 'text/html');
                return collect(doc, url);
            } catch (error) {
                return null;
            }
        }

        (async function() {
            var snapshot = collect(document, window.location.href);
            var urls = candidateUrls();

            for (var i = 0; i < urls.length; i++) {
                var remote = await fetchSnapshot(urls[i]);
                snapshot = betterSnapshot(snapshot, remote);
            }

            handler.postMessage(snapshot);
        })().catch(function(error) {
            handler.postMessage({
                totalCount: extractTotalCount(document),
                details: extractDetails(document),
                error: trimText(String(error || 'unknown'))
            });
        });

        return 'birdz-monitor-ran';
    })();
    """#
}

final class BirdzNotificationMonitor: NSObject {
    static let shared = BirdzNotificationMonitor()

    private let messageHandlerName = "birdzNotificationMonitor"

    private weak var webView: WKWebView?
    private var timer: Timer?
    private var lastBadgeCount: Int = -1
    private var lastNotificationSignatures = Set<String>()
    private var hasPinnedWebViewToSafeArea = false

    func startMonitoring(webView: WKWebView) {
        self.webView = webView

        DispatchQueue.main.async { [weak self] in
            self?.pinWebViewToSafeArea()
        }

        configureMessageBridge(for: webView)
        requestNotificationPermissionIfNeeded()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.runMonitor()
        }

        runMonitor()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.pinWebViewToSafeArea()
            self?.runMonitor()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil

        webView?.configuration.userContentController.removeScriptMessageHandler(forName: messageHandlerName)
        webView = nil
        hasPinnedWebViewToSafeArea = false
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
            self?.pinWebViewToSafeArea()
            webView.evaluateJavaScript(BirdzNotificationScrapeScript.source) { _, error in
                if let error {
                    print("BirdzMonitor: JS inject error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func pinWebViewToSafeArea() {
        guard let webView, let containerView = webView.superview else { return }

        webView.scrollView.contentInsetAdjustmentBehavior = .never

        if !hasPinnedWebViewToSafeArea {
            let constraintsToRemove = containerView.constraints.filter {
                ($0.firstItem as AnyObject?) === webView || ($0.secondItem as AnyObject?) === webView
            }
            NSLayoutConstraint.deactivate(constraintsToRemove)

            webView.translatesAutoresizingMaskIntoConstraints = false
            webView.autoresizingMask = []

            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.topAnchor),
                webView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
            ])

            hasPinnedWebViewToSafeArea = true
        }

        containerView.setNeedsLayout()
        containerView.layoutIfNeeded()

        if webView.scrollView.contentOffset.y < 0 {
            webView.scrollView.setContentOffset(.zero, animated: false)
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
