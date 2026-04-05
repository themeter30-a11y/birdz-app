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
    private let detailHandlerName = "birdzDetailScraper"
    private var didInstallScripts = false
    private var lastAppliedTopInset: CGFloat = 0

    // Hidden webview for scraping /reakcie/ page
    private var scraperWebView: WKWebView?
    private var pendingBadge: Int = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        UNUserNotificationCenter.current().delegate = self
        registerLifecycleObservers()
        requestNotificationPermission()
        configureWebViewIfNeeded()
        setupScraperWebView()
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
        scraperWebView?.configuration.userContentController.removeScriptMessageHandler(forName: detailHandlerName)
    }

    @objc private func handleAppDidBecomeActive() {
        configureWebViewIfNeeded()
        startPolling()
        runScrape()
    }

    @objc private func handleAppWillResignActive() {
        // Keep polling every 5 seconds even in background
    }

    private func registerLifecycleObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppWillResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    // MARK: - WebView Configuration

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

        // Add pinch-to-zoom gesture recognizer as backup
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        wv.scrollView.addGestureRecognizer(pinch)

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

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        // Native pinch handled by scrollView zoom
    }

    private func setupScraperWebView() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: detailHandlerName)

        let scraper = WKWebView(frame: .zero, configuration: config)
        scraper.isHidden = true
        view.addSubview(scraper)
        scraperWebView = scraper
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
                CGPoint(x: wv.scrollView.contentOffset.x, y: -topInset), animated: false
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

    private func startBackgroundPolling() {
        backgroundPollTimer?.invalidate()
        backgroundPollTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            self?.runScrape()
        }
    }

    private func runScrape() {
        guard let wv = webView else { return }
        DispatchQueue.main.async {
            wv.evaluateJavaScript(BirdzScrapeJS.source) { _, error in
                if let error = error {
                    print("BirdzViewController: JS scrape error: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Scrape /reakcie/ for detail info

    private func scrapeReakcieForDetails(badge: Int) {
        pendingBadge = badge
        guard let scraper = scraperWebView,
              let url = URL(string: "https://www.birdz.sk/reakcie/") else { return }
        scraper.load(URLRequest(url: url))

        // After page loads, inject scraping JS
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.scraperWebView?.evaluateJavaScript(BirdzReakcieScrapeJS.source) { _, error in
                if let error = error {
                    print("BirdzViewController: Reakcie scrape error: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Process notification payload from main page

    private func processPayload(_ payload: [String: Any]) {
        let totalCount = payload["totalCount"] as? Int ?? 0

        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = totalCount
        }

        // First run — just store state
        guard lastBadgeCount >= 0 else {
            lastBadgeCount = totalCount
            return
        }

        // Badge increased — scrape /reakcie/ for details
        if totalCount > lastBadgeCount {
            scrapeReakcieForDetails(badge: totalCount)
        }

        lastBadgeCount = totalCount
    }

    // MARK: - Process detail payload from /reakcie/

    private func processDetailPayload(_ payload: [String: Any]) {
        let details = payload["details"] as? [[String: Any]] ?? []
        let newSignatures = Set(details.map { sig($0) })

        let unseen = details.filter { !lastSignatures.contains(sig($0)) }

        if !unseen.isEmpty {
            for detail in unseen {
                let type = detail["type"] as? String ?? "Upozornenie"
                let text = detail["text"] as? String ?? "Máš novú notifikáciu"

                sendNotification(
                    title: "Birdz – \(type)",
                    body: text,
                    badge: pendingBadge,
                    deepLink: "https://www.birdz.sk/reakcie/"
                )
            }
        } else if pendingBadge > lastBadgeCount {
            let diff = pendingBadge - lastBadgeCount
            sendNotification(
                title: "Birdz",
                body: diff == 1 ? "Máš novú notifikáciu" : "Máš \(diff) nových notifikácií",
                badge: pendingBadge,
                deepLink: "https://www.birdz.sk/reakcie/"
            )
        }

        lastSignatures = newSignatures
    }

    private func sig(_ detail: [String: Any]) -> String {
        let type = detail["type"] as? String ?? ""
        let text = detail["text"] as? String ?? ""
        return "\(type)|\(text)"
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
                print("BirdzViewController: Notification error: \(error.localizedDescription)")
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

// MARK: - UIGestureRecognizerDelegate

extension BirdzViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

// MARK: - WKScriptMessageHandler

extension BirdzViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == handlerName, let payload = message.body as? [String: Any] {
            processPayload(payload)
        } else if message.name == detailHandlerName, let payload = message.body as? [String: Any] {
            processDetailPayload(payload)
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension BirdzViewController: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }

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

// MARK: - JavaScript: WebView enhancements (viewport zoom + touch + CSS overrides)

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
            var desired = 'width=device-width, initial-scale=1.0, minimum-scale=1.0, maximum-scale=5.0, user-scalable=yes, viewport-fit=cover';
            if (meta.getAttribute('content') !== desired) {
                meta.setAttribute('content', desired);
            }
        }

        function forceZoomCSS() {
            var id = 'birdz-zoom-fix';
            if (document.getElementById(id)) return;
            var head = document.head || document.getElementsByTagName('head')[0];
            if (!head) return;
            var style = document.createElement('style');
            style.id = id;
            style.textContent = [
                '* { touch-action: auto !important; -ms-touch-action: auto !important; }',
                'html, body { touch-action: manipulation !important; }',
                'html, body, a, img { -webkit-touch-callout: default !important; }',
                'a, img { -webkit-user-select: auto !important; user-select: auto !important; }',
                'body { -webkit-text-size-adjust: 100% !important; }',
                'img { pointer-events: auto !important; }'
            ].join('\n');
            head.appendChild(style);
        }

        function killZoomBlockers() {
            // Remove any JS that blocks pinch zoom
            document.addEventListener('touchstart', function(e) {}, {passive: true});
            document.addEventListener('touchmove', function(e) {}, {passive: true});
            document.addEventListener('gesturestart', function(e) { e.stopPropagation(); }, true);
            document.addEventListener('gesturechange', function(e) { e.stopPropagation(); }, true);
            document.addEventListener('gestureend', function(e) { e.stopPropagation(); }, true);
        }

        function applyAll() {
            forceZoomableViewport();
            forceZoomCSS();
            killZoomBlockers();
        }

        applyAll();
        document.addEventListener('DOMContentLoaded', applyAll, false);
        window.addEventListener('load', applyAll, false);

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

        setInterval(function() {
            forceZoomableViewport();
            forceZoomCSS();
        }, 2000);

        return 'birdz-enhancements-v3';
    })();
    """#
}

// MARK: - JavaScript: Badge count scraping (runs on main page every 5s)

private enum BirdzScrapeJS {
    static let source = #"""
    (function() {
        var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.birdzNotificationMonitor;
        if (!handler) return 'no-handler';

        function trimText(v) { return (v || '').replace(/\s+/g, ' ').trim(); }

        function parseCount(text) {
            var m = trimText(text).match(/\d+/);
            return m ? parseInt(m[0], 10) : 0;
        }

        // Look for the red badge number in top-right corner
        function extractTotalCount() {
            // Try badge selectors used by birdz.sk
            var selectors = [
                '.button-more .badge',
                '.header_user_avatar .badge',
                '.header .badge',
                '.badge',
                '[class*="notif"] .badge',
                '.notification-count',
                '.notif-count'
            ];
            for (var i = 0; i < selectors.length; i++) {
                var els = document.querySelectorAll(selectors[i]);
                for (var j = 0; j < els.length; j++) {
                    var v = parseCount(els[j].textContent);
                    if (v > 0) return v;
                }
            }

            // Fallback: any small number in header area
            var header = document.querySelector('header, .header, #header, nav, .page-content-wrapper');
            if (!header) return 0;
            var nodes = header.querySelectorAll('span, div, sup, strong, b, a');
            for (var k = 0; k < nodes.length; k++) {
                var el = nodes[k];
                var text = trimText(el.textContent);
                if (/^\d+$/.test(text)) {
                    var v = parseInt(text, 10);
                    if (v > 0 && v < 1000 && el.offsetWidth < 60 && el.offsetHeight < 60) return v;
                }
            }
            return 0;
        }

        handler.postMessage({
            totalCount: extractTotalCount(),
            sourceUrl: window.location.href
        });

        return 'birdz-badge-scraped';
    })();
    """#
}

// MARK: - JavaScript: Scrape /reakcie/ for notification details (bold = new)

private enum BirdzReakcieScrapeJS {
    static let source = #"""
    (function() {
        var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.birdzDetailScraper;
        if (!handler) return 'no-detail-handler';

        function trimText(v) { return (v || '').replace(/\s+/g, ' ').trim(); }

        function detectType(text) {
            var v = text.toLowerCase();
            if (v.indexOf('tajn') > -1 || v.indexOf('správ') > -1 || v.indexOf('sprav') > -1) return 'Tajná správa';
            if (v.indexOf('reakci') > -1 || v.indexOf('status') > -1) return 'Reakcia na status';
            if (v.indexOf('koment') > -1 && v.indexOf('blog') > -1) return 'Komentár k blogu';
            if (v.indexOf('koment') > -1 && (v.indexOf('fotk') > -1 || v.indexOf('album') > -1 || v.indexOf('obráz') > -1)) return 'Komentár k fotke';
            if (v.indexOf('koment') > -1) return 'Komentár';
            if (v.indexOf('sleduj') > -1) return 'Nový sledovateľ';
            if (v.indexOf('označil') > -1 || v.indexOf('oznacil') > -1) return 'Označenie';
            if (v.indexOf('blog') > -1) return 'Blog';
            if (v.indexOf('fotk') > -1 || v.indexOf('album') > -1) return 'Fotka';
            return 'Upozornenie';
        }

        // On /reakcie/ page, new (unread) items are bold
        var details = [];
        var items = document.querySelectorAll('li, .item, .notification-item, [class*="reakci"], [class*="notif"], tr, .row');
        for (var i = 0; i < items.length; i++) {
            var item = items[i];
            var text = trimText(item.textContent);
            if (!text || text.length < 5) continue;

            // Check if item is bold (unread/new)
            var isBold = false;
            var bolds = item.querySelectorAll('strong, b, [style*="bold"], [class*="bold"], [class*="unread"], [class*="new"]');
            if (bolds.length > 0) isBold = true;
            if (!isBold) {
                var cs = window.getComputedStyle(item);
                if (cs.fontWeight === 'bold' || parseInt(cs.fontWeight) >= 700) isBold = true;
            }

            if (isBold && text.length > 5 && text.length < 500) {
                details.push({
                    type: detectType(text),
                    text: text.slice(0, 200)
                });
            }
            if (details.length >= 5) break;
        }

        handler.postMessage({ details: details });
        return 'birdz-reakcie-scraped';
    })();
    """#
}
