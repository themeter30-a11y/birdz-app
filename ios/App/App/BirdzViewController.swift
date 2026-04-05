import UIKit
import Capacitor
import WebKit
import UserNotifications

final class BirdzViewController: CAPBridgeViewController {

    private var pollTimer: Timer?
    private var lastBadgeCount: Int = -1
    private var lastSignatures = Set<String>()
    private var refreshControl: UIRefreshControl?
    private let handlerName = "birdzNotificationMonitor"
    private var didInstallScripts = false
    private var lastAppliedTopInset: CGFloat = 0

    override func viewDidLoad() {
        super.viewDidLoad()

        registerLifecycleObservers()
        requestNotificationPermission()
        configureWebViewIfNeeded()
        startPolling()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        configureWebViewIfNeeded()
        startPolling()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateWebViewInsets()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateWebViewInsets()
    }

    deinit {
        stopPolling()
        NotificationCenter.default.removeObserver(self)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: handlerName)
    }

    @objc private func handleAppDidBecomeActive() {
        configureWebViewIfNeeded()
        startPolling()
        runScrape()
    }

    @objc private func handleAppWillResignActive() {
        stopPolling()
    }

    private func registerLifecycleObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
    }

    private func configureWebViewIfNeeded() {
        guard let wv = webView else { return }

        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.scrollView.minimumZoomScale = 1.0
        wv.scrollView.maximumZoomScale = 5.0
        wv.scrollView.bouncesZoom = true
        wv.scrollView.bounces = true
        wv.scrollView.alwaysBounceVertical = true
        wv.scrollView.keyboardDismissMode = .interactive
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsLinkPreview = true

        if refreshControl == nil {
            let rc = UIRefreshControl()
            rc.tintColor = .systemRed
            rc.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
            wv.scrollView.addSubview(rc)
            refreshControl = rc
        }

        let controller = wv.configuration.userContentController
        controller.removeScriptMessageHandler(forName: handlerName)
        controller.add(self, name: handlerName)

        if !didInstallScripts {
            let script = WKUserScript(
                source: BirdzWebViewJS.source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            controller.addUserScript(script)
            didInstallScripts = true
        }

        wv.evaluateJavaScript(BirdzWebViewJS.source, completionHandler: nil)
        updateWebViewInsets()
    }

    private func updateWebViewInsets() {
        guard let wv = webView else { return }

        let topInset = max(view.safeAreaInsets.top, 0)
        guard abs(topInset - lastAppliedTopInset) > 0.5 else { return }

        let previousTopInset = lastAppliedTopInset

        var contentInset = wv.scrollView.contentInset
        contentInset.top = topInset
        wv.scrollView.contentInset = contentInset

        var indicatorInsets = wv.scrollView.scrollIndicatorInsets
        indicatorInsets.top = topInset
        wv.scrollView.scrollIndicatorInsets = indicatorInsets

        if previousTopInset == 0 || abs(wv.scrollView.contentOffset.y + previousTopInset) < 2 {
            wv.scrollView.setContentOffset(
                CGPoint(x: wv.scrollView.contentOffset.x, y: -topInset),
                animated: false
            )
        }

        lastAppliedTopInset = topInset
    }

    @objc private func handleRefresh() {
        webView?.reload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshControl?.endRefreshing()
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
            }
        }
    }

    private func startPolling() {
        stopPolling()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.runScrape()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.runScrape()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func runScrape() {
        guard let wv = webView else { return }
        DispatchQueue.main.async {
            wv.evaluateJavaScript(BirdzScrapeJS.source) { _, error in
                if let error = error {
                    print("BirdzViewController: JS error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func processPayload(_ payload: [String: Any]) {
        let totalCount = payload["totalCount"] as? Int ?? 0
        let details = payload["details"] as? [[String: Any]] ?? []

        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = totalCount
        }

        guard lastBadgeCount >= 0 else {
            lastBadgeCount = totalCount
            lastSignatures = Set(details.map { sig($0) })
            return
        }

        if totalCount > lastBadgeCount {
            let newCount = totalCount - lastBadgeCount
            let unseen = details.filter { !lastSignatures.contains(sig($0)) }

            if !unseen.isEmpty {
                for detail in unseen.prefix(max(newCount, 1)) {
                    sendDetailNotification(detail, badge: totalCount)
                }
            } else {
                sendNotification(
                    title: "Birdz",
                    body: newCount == 1 ? "Máš novú notifikáciu" : "Máš \(newCount) nových notifikácií",
                    badge: totalCount
                )
            }
        }

        lastBadgeCount = totalCount
        lastSignatures = Set(details.map { sig($0) })
    }

    private func sig(_ detail: [String: Any]) -> String {
        let type = detail["type"] as? String ?? ""
        let sender = detail["sender"] as? String ?? ""
        let preview = detail["preview"] as? String ?? ""
        return [type, sender, preview].joined(separator: "|")
    }

    private func sendDetailNotification(_ detail: [String: Any], badge: Int) {
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

        sendNotification(title: "Birdz – \(type)", body: body, badge: badge)
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
            if let error = error {
                print("BirdzViewController: Chyba notifikácie: \(error.localizedDescription)")
            }
        }
    }
}

extension BirdzViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == handlerName,
              let payload = message.body as? [String: Any] else { return }

        processPayload(payload)
    }
}

private enum BirdzWebViewJS {
    static let source = #"""
    (function() {
        window.__birdzApplyNativeEnhancements = window.__birdzApplyNativeEnhancements || function() {
            function ensureViewport() {
                var head = document.head || document.getElementsByTagName('head')[0];
                var meta = document.querySelector('meta[name="viewport"]');

                if (!meta) {
                    if (!head) return;
                    meta = document.createElement('meta');
                    meta.name = 'viewport';
                    head.appendChild(meta);
                }

                var next = [
                    'width=device-width',
                    'initial-scale=1.0',
                    'maximum-scale=5.0',
                    'user-scalable=yes',
                    'viewport-fit=cover'
                ].join(', ');

                meta.setAttribute('content', next);
            }

            function ensureTouchCallout() {
                var head = document.head || document.getElementsByTagName('head')[0];
                if (!head || document.getElementById('birdz-ios-webview-style')) return;

                var style = document.createElement('style');
                style.id = 'birdz-ios-webview-style';
                style.textContent = [
                    'html, body, a, img { -webkit-touch-callout: default !important; }',
                    'a, img { -webkit-user-select: auto !important; user-select: auto !important; }'
                ].join(' ');

                head.appendChild(style);
            }

            ensureViewport();
            ensureTouchCallout();
        };

        window.__birdzApplyNativeEnhancements();
        document.addEventListener('DOMContentLoaded', window.__birdzApplyNativeEnhancements, false);
        window.addEventListener('load', window.__birdzApplyNativeEnhancements, false);
        return 'birdz-webview-enhancements-ready';
    })();
    """#
}

private enum BirdzScrapeJS {
    static let source = #"""
    (function() {
        var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.birdzNotificationMonitor;
        if (!handler) return 'birdz-handler-missing';

        function trimText(v) { return (v || '').replace(/\s+/g, ' ').trim(); }

        function parseCount(text) {
            var m = trimText(text).match(/\d+/);
            return m ? parseInt(m[0], 10) : 0;
        }

        function detectType(text) {
            var v = trimText(text).toLowerCase();
            if (v.indexOf('tajn') > -1 || v.indexOf('správ') > -1 || v.indexOf('sprav') > -1) return 'Tajná správa';
            if (v.indexOf('reakci') > -1) return 'Reakcia na status';
            if (v.indexOf('koment') > -1) return 'Komentár';
            if (v.indexOf('sleduj') > -1) return 'Nový sledovateľ';
            if (v.indexOf('označil') > -1 || v.indexOf('oznacil') > -1) return 'Označenie';
            return 'Upozornenie';
        }

        function extractTotalCount(root) {
            var badges = root.querySelectorAll('.button-more .badge, .header_user_avatar .badge, .header .badge, .badge, [class*="notif"] .badge');
            for (var i = 0; i < badges.length; i++) {
                var v = parseCount(badges[i].textContent);
                if (v > 0) return v;
            }
            var header = root.querySelector('header, .header, #header, nav');
            if (!header) return 0;
            var nodes = header.querySelectorAll('span, div, a, sup, strong, b');
            for (var j = 0; j < nodes.length; j++) {
                var v = parseCount(nodes[j].textContent);
                if (v > 0 && v < 1000) return v;
            }
            return 0;
        }

        function pickPreview(container) {
            var selectors = ['.message', '.preview', '.description', '.text', '[class*="message"]', '[class*="preview"]', 'p', 'span'];
            for (var i = 0; i < selectors.length; i++) {
                var el = container.querySelector(selectors[i]);
                var text = trimText(el && el.textContent);
                if (text && !/^\d+$/.test(text)) return text.slice(0, 220);
            }
            return trimText(container.textContent).slice(0, 220);
        }

        function pickSender(container) {
            var selectors = ['.username', '.user', '.name', '[class*="username"]', '[class*="sender"]', 'strong', 'b', 'a[href*="profil"]'];
            for (var i = 0; i < selectors.length; i++) {
                var el = container.querySelector(selectors[i]);
                var text = trimText(el && el.textContent);
                if (text && !/^\d+$/.test(text)) return text.slice(0, 80);
            }
            return '';
        }

        function extractDetails(root) {
            var containers = root.querySelectorAll('.notifications-list li, .notification-item, [class*="notif"] li, [class*="notification"] li, .dropdown-menu li, .list-group-item, [class*="notification"]');
            var details = [], seen = {};
            for (var i = 0; i < containers.length; i++) {
                var container = containers[i];
                var fullText = trimText(container.textContent);
                if (!fullText) continue;
                var detail = { type: detectType(fullText), sender: pickSender(container), preview: pickPreview(container), count: 1 };
                var signature = [detail.type, detail.sender, detail.preview].join('|');
                if (seen[signature]) continue;
                seen[signature] = true;
                details.push(detail);
                if (details.length >= 10) break;
            }
            return details;
        }

        handler.postMessage({
            totalCount: extractTotalCount(document),
            details: extractDetails(document),
            sourceUrl: window.location.href
        });

        return 'birdz-monitor-ran';
    })();
    """#
}
