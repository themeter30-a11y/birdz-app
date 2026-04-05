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

        // Register as notification delegate so we can handle taps
        UNUserNotificationCenter.current().delegate = self

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

    // MARK: - Polling

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
            // First reload the page silently to get fresh data
            wv.evaluateJavaScript("void(0)", completionHandler: nil)
            // Then run the scrape
            wv.evaluateJavaScript(BirdzScrapeJS.source) { _, error in
                if let error = error {
                    print("BirdzViewController: JS error: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Process notification payload

    private func processPayload(_ payload: [String: Any]) {
        let totalCount = payload["totalCount"] as? Int ?? 0
        let details = payload["details"] as? [[String: Any]] ?? []
        let sourceUrl = payload["sourceUrl"] as? String ?? "https://birdz.sk"

        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = totalCount
        }

        // First run - just store state
        guard lastBadgeCount >= 0 else {
            lastBadgeCount = totalCount
            lastSignatures = Set(details.map { sig($0) })
            return
        }

        // Badge increased - new notifications arrived
        if totalCount > lastBadgeCount {
            let unseen = details.filter { !lastSignatures.contains(sig($0)) }

            if !unseen.isEmpty {
                for detail in unseen {
                    sendDetailNotification(detail, badge: totalCount, baseUrl: sourceUrl)
                }
            } else {
                let newCount = totalCount - lastBadgeCount
                sendNotification(
                    title: "Birdz",
                    body: newCount == 1 ? "Máš novú notifikáciu" : "Máš \(newCount) nových notifikácií",
                    badge: totalCount,
                    deepLink: "https://birdz.sk/notifikacie"
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

    private func sendDetailNotification(_ detail: [String: Any], badge: Int, baseUrl: String) {
        let type = detail["type"] as? String ?? "Upozornenie"
        let sender = detail["sender"] as? String ?? ""
        let preview = detail["preview"] as? String ?? ""
        let link = detail["link"] as? String ?? ""

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

        // Determine deep link based on notification type
        var deepLink = "https://birdz.sk/notifikacie"
        if !link.isEmpty {
            if link.hasPrefix("http") {
                deepLink = link
            } else {
                deepLink = "https://birdz.sk\(link.hasPrefix("/") ? "" : "/")\(link)"
            }
        } else if type.contains("správ") || type.contains("Tajn") {
            deepLink = "https://birdz.sk/tajne-spravy"
        }

        sendNotification(title: "Birdz – \(type)", body: body, badge: badge, deepLink: deepLink)
    }

    private func sendNotification(title: String, body: String, badge: Int, deepLink: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.badge = NSNumber(value: badge)
        content.userInfo = ["deepLink": deepLink]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
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

    // MARK: - Deep link navigation

    private func navigateToURL(_ urlString: String) {
        guard let wv = webView else { return }
        DispatchQueue.main.async {
            wv.evaluateJavaScript("window.location.href = '\(urlString)';", completionHandler: nil)
        }
    }
}

// MARK: - WKScriptMessageHandler

extension BirdzViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == handlerName,
              let payload = message.body as? [String: Any] else { return }

        processPayload(payload)
    }
}

// MARK: - UNUserNotificationCenterDelegate (handle notification taps)

extension BirdzViewController: UNUserNotificationCenterDelegate {

    // Show notification even when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }

    // Handle notification tap - navigate to deep link
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let deepLink = userInfo["deepLink"] as? String {
            navigateToURL(deepLink)
        }
        completionHandler()
    }
}

// MARK: - JavaScript: WebView enhancements (viewport zoom + touch)

private enum BirdzWebViewJS {
    static let source = #"""
    (function() {
        function forceZoomableViewport() {
            var meta = document.querySelector('meta[name="viewport"]');
            if (!meta) {
                var head = document.head || document.getElementsByTagName('head')[0];
                if (!head) return;
                meta = document.createElement('meta');
                meta.name = 'viewport';
                head.appendChild(meta);
            }
            var desired = 'width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes, viewport-fit=cover';
            if (meta.getAttribute('content') !== desired) {
                meta.setAttribute('content', desired);
            }
        }

        function ensureTouchCallout() {
            if (document.getElementById('birdz-ios-style')) return;
            var head = document.head || document.getElementsByTagName('head')[0];
            if (!head) return;
            var style = document.createElement('style');
            style.id = 'birdz-ios-style';
            style.textContent = [
                'html, body, a, img { -webkit-touch-callout: default !important; }',
                'a, img { -webkit-user-select: auto !important; user-select: auto !important; }',
                'body { -webkit-text-size-adjust: 100% !important; }'
            ].join('\n');
            head.appendChild(style);
        }

        function applyAll() {
            forceZoomableViewport();
            ensureTouchCallout();
        }

        // Apply immediately
        applyAll();

        // Apply on DOM ready and load
        document.addEventListener('DOMContentLoaded', applyAll, false);
        window.addEventListener('load', applyAll, false);

        // Watch for any script that tries to change the viewport back
        if (window.MutationObserver) {
            var observer = new MutationObserver(function(mutations) {
                for (var i = 0; i < mutations.length; i++) {
                    var m = mutations[i];
                    if (m.type === 'attributes' && m.target.tagName === 'META' && m.target.name === 'viewport') {
                        forceZoomableViewport();
                    }
                    if (m.type === 'childList') {
                        var added = m.addedNodes;
                        for (var j = 0; j < added.length; j++) {
                            if (added[j].tagName === 'META' && added[j].name === 'viewport') {
                                forceZoomableViewport();
                            }
                        }
                    }
                }
            });

            function startObserving() {
                var head = document.head || document.getElementsByTagName('head')[0];
                if (head) {
                    observer.observe(head, { childList: true, attributes: true, subtree: true, attributeFilter: ['content'] });
                }
            }

            startObserving();
            document.addEventListener('DOMContentLoaded', startObserving, false);
        }

        // Also re-apply every 2 seconds as a safety net
        setInterval(forceZoomableViewport, 2000);

        return 'birdz-enhancements-v2';
    })();
    """#
}

// MARK: - JavaScript: Notification scraping

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
            if (v.indexOf('blog') > -1) return 'Komentár k blogu';
            if (v.indexOf('fotk') > -1 || v.indexOf('album') > -1) return 'Komentár k fotke';
            return 'Upozornenie';
        }

        function extractTotalCount(root) {
            // Try common badge selectors
            var badges = root.querySelectorAll('.button-more .badge, .header_user_avatar .badge, .header .badge, .badge, [class*="notif"] .badge');
            for (var i = 0; i < badges.length; i++) {
                var v = parseCount(badges[i].textContent);
                if (v > 0) return v;
            }
            // Fallback: look in header area
            var header = root.querySelector('header, .header, #header, nav');
            if (!header) return 0;
            var nodes = header.querySelectorAll('span, div, a, sup, strong, b');
            for (var j = 0; j < nodes.length; j++) {
                var el = nodes[j];
                var text = trimText(el.textContent);
                if (/^\d+$/.test(text)) {
                    var v = parseInt(text, 10);
                    if (v > 0 && v < 1000) return v;
                }
            }
            return 0;
        }

        function pickPreview(container) {
            var selectors = ['.message', '.preview', '.description', '.text', '[class*="message"]', '[class*="preview"]', 'p', 'span'];
            for (var i = 0; i < selectors.length; i++) {
                var el = container.querySelector(selectors[i]);
                var text = trimText(el && el.textContent);
                if (text && text.length > 3 && !/^\d+$/.test(text)) return text.slice(0, 220);
            }
            return trimText(container.textContent).slice(0, 220);
        }

        function pickSender(container) {
            var selectors = ['.username', '.user', '.name', '[class*="username"]', '[class*="sender"]', 'strong', 'b', 'a[href*="profil"]'];
            for (var i = 0; i < selectors.length; i++) {
                var el = container.querySelector(selectors[i]);
                var text = trimText(el && el.textContent);
                if (text && text.length > 1 && !/^\d+$/.test(text)) return text.slice(0, 80);
            }
            return '';
        }

        function pickLink(container) {
            var a = container.querySelector('a[href]');
            return a ? a.getAttribute('href') : '';
        }

        function extractDetails(root) {
            var containers = root.querySelectorAll('.notifications-list li, .notification-item, [class*="notif"] li, [class*="notification"] li, .dropdown-menu li, .list-group-item, [class*="notification"]');
            var details = [], seen = {};
            for (var i = 0; i < containers.length; i++) {
                var container = containers[i];
                var fullText = trimText(container.textContent);
                if (!fullText || fullText.length < 3) continue;
                var detail = {
                    type: detectType(fullText),
                    sender: pickSender(container),
                    preview: pickPreview(container),
                    link: pickLink(container),
                    count: 1
                };
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
