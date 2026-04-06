import UIKit
import Capacitor
import WebKit
import UserNotifications

final class BirdzViewController: CAPBridgeViewController {

    private enum StorageKeys {
        static let lastContentHash = "birdz_last_content_hash"
        static let unreadBadge = "birdz_unread_badge"
        static let lastDeliveredContentHash = "birdz_last_delivered_content_hash"
    }

    // MARK: - Properties

    private var pollTimer: Timer?
    private var refreshControl: UIRefreshControl?
    private var didInstallScripts = false
    private var lastAppliedTopInset: CGFloat = 0

    // Scraper: hidden webview that loads /reakcie/ every 5s
    private var scraperWebView: WKWebView?
    private let scraperHandler = "birdzReakcieScraper"
    private var lastContentHash: String = UserDefaults.standard.string(forKey: StorageKeys.lastContentHash) ?? ""
    private var scraperIsLoading = false
    private var scraperTimeoutWorkItem: DispatchWorkItem?

    override func viewDidLoad() {
        super.viewDidLoad()
        // Delegate is set in AppDelegate for reliability
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
        scraperWebView?.configuration.userContentController.removeScriptMessageHandler(forName: scraperHandler)
    }

    // MARK: - Lifecycle

    @objc private func handleAppDidBecomeActive() {
        configureWebViewIfNeeded()
        syncSystemBadge(with: UserDefaults.standard.integer(forKey: StorageKeys.unreadBadge))
        startPolling()
    }

    @objc private func handleAppWillResignActive() {
        // Foreground timer pauses in background by iOS design.
    }

    private func registerLifecycleObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppWillResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    // MARK: - Main WebView Configuration

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

        let hasCustomPinch = wv.scrollView.gestureRecognizers?.contains(where: { gesture in
            guard let pinch = gesture as? UIPinchGestureRecognizer else { return false }
            return pinch.delegate === self
        }) ?? false

        if !hasCustomPinch {
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.delegate = self
            wv.scrollView.addGestureRecognizer(pinch)
        }

        if refreshControl == nil {
            let rc = UIRefreshControl()
            rc.tintColor = .systemRed
            rc.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
            wv.scrollView.addSubview(rc)
            refreshControl = rc
        }

        if !didInstallScripts {
            let script = WKUserScript(
                source: BirdzWebViewJS.source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            wv.configuration.userContentController.addUserScript(script)
            didInstallScripts = true
        }

        wv.evaluateJavaScript(BirdzWebViewJS.source, completionHandler: nil)
        updateWebViewInsets()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {}

    private func updateWebViewInsets() {
        guard let wv = webView else { return }
        let topInset = max(view.safeAreaInsets.top, 0)
        guard abs(topInset - lastAppliedTopInset) > 0.5 else { return }
        let prev = lastAppliedTopInset

        var ci = wv.scrollView.contentInset
        ci.top = topInset
        wv.scrollView.contentInset = ci

        var si = wv.scrollView.scrollIndicatorInsets
        si.top = topInset
        wv.scrollView.scrollIndicatorInsets = si

        if prev == 0 || abs(wv.scrollView.contentOffset.y + prev) < 2 {
            wv.scrollView.setContentOffset(CGPoint(x: wv.scrollView.contentOffset.x, y: -topInset), animated: false)
        }
        lastAppliedTopInset = topInset
    }

    @objc private func handleRefresh() {
        webView?.reload()
        loadReakciePage()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshControl?.endRefreshing()
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error {
                print("BirdzScraper: Auth error: \(error.localizedDescription)")
                return
            }
            print("BirdzScraper: Permission granted=\(granted)")
        }
    }

    // MARK: - Hidden Scraper WebView (polls /reakcie/ every 5s)

    private func setupScraperWebView() {
        guard scraperWebView == nil else { return }

        let config = WKWebViewConfiguration()
        config.processPool = webView?.configuration.processPool ?? WKProcessPool()
        config.websiteDataStore = webView?.configuration.websiteDataStore ?? .default()
        config.userContentController.add(self, name: scraperHandler)

        let scraper = WKWebView(frame: .zero, configuration: config)
        scraper.isHidden = true
        scraper.navigationDelegate = self
        scraper.scrollView.isScrollEnabled = false
        view.addSubview(scraper)
        scraperWebView = scraper
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        loadReakciePage()

        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.loadReakciePage()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        scraperTimeoutWorkItem?.cancel()
        scraperTimeoutWorkItem = nil
        scraperIsLoading = false
    }

    private func armScraperTimeout() {
        scraperTimeoutWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scraperIsLoading = false
            self.scraperWebView?.stopLoading()
            print("BirdzScraper: Load timeout")
        }

        scraperTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: workItem)
    }

    private func loadReakciePage() {
        guard !scraperIsLoading else { return }
        guard let scraper = scraperWebView else { return }

        var components = URLComponents(string: "https://www.birdz.sk/reakcie/")
        components?.queryItems = [
            URLQueryItem(name: "_birdz_ts", value: String(Int(Date().timeIntervalSince1970 * 1000)))
        ]

        guard let url = components?.url else { return }

        scraperIsLoading = true
        scraper.stopLoading()

        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        scraper.load(request)
        armScraperTimeout()
    }

    // MARK: - Process scraped data from /reakcie/

    private func processScrapedItems(_ payload: [String: Any]) {
        let contentHash = payload["contentHash"] as? String ?? ""
        let items = payload["items"] as? [[String: Any]] ?? []
        let rawText = payload["rawText"] as? String ?? ""
        let unreadBadge = max(payload["unreadBadge"] as? Int ?? 0, 0)
        let previousUnreadBadge = UserDefaults.standard.integer(forKey: StorageKeys.unreadBadge)

        let normalizedRawText = rawText.lowercased()
        let parsedItems = items.map(BirdzScrapedNotificationItem.init).filter { $0.isMeaningful }
        let preferredItems = parsedItems.filter { !$0.text.isEmpty }
        let notificationItems = preferredItems.isEmpty ? parsedItems : preferredItems
        let skip = unreadBadge == 0 && notificationItems.isEmpty && (
            normalizedRawText.contains("0 nových komment") ||
            normalizedRawText.contains("0 nových koment") ||
            normalizedRawText.contains("0 novych koment")
        )
        let effectiveUnreadCount = skip ? 0 : unreadBadge
        let missingItems = BirdzNotificationSyncStore.unsentItems(from: notificationItems, unreadCount: effectiveUnreadCount)
        let didUnreadCountIncrease = unreadBadge > previousUnreadBadge

        syncSystemBadge(with: unreadBadge)

        guard !contentHash.isEmpty else { return }

        let isInitialState = lastContentHash.isEmpty
        let didContentChange = contentHash != lastContentHash
        print("BirdzScraper: hash=\(contentHash) prev=\(lastContentHash) badge=\(unreadBadge) prevBadge=\(previousUnreadBadge) items=\(notificationItems.count) missing=\(missingItems.count)")

        storeLastContentHash(contentHash)

        guard !skip else {
            print("BirdzScraper: Skipping notification – 0 nových komentárov")
            return
        }

        guard !isInitialState else { return }

        let shouldNotify = didContentChange && unreadBadge > 0
        let shouldForceNotify = didUnreadCountIncrease && unreadBadge > 0
        let hasMissing = !missingItems.isEmpty

        guard shouldNotify || shouldForceNotify || hasMissing else {
            print("BirdzScraper: No notification needed (changed=\(didContentChange) badge=\(unreadBadge) increased=\(didUnreadCountIncrease) missing=\(missingItems.count))")
            return
        }

        print("BirdzScraper: 🔔 Will send notification! reason: changed=\(shouldNotify) forced=\(shouldForceNotify) missing=\(hasMissing)")

        if !missingItems.isEmpty {
            for (index, item) in missingItems.enumerated() {
                sendNotification(for: item, badge: unreadBadge, delay: 1.0 + (Double(index) * 0.8))
            }
        } else {
            let fallbackBody: String
            if let firstItem = notificationItems.first, !firstItem.text.isEmpty {
                fallbackBody = firstItem.text
            } else {
                fallbackBody = rawText.isEmpty ? "Máš novú aktivitu v reakciách" : String(rawText.prefix(260))
            }
            sendNotification(title: "Birdz", body: fallbackBody, badge: unreadBadge)
        }
    }

    private func sendNotification(for item: BirdzScrapedNotificationItem, badge: Int, delay: TimeInterval) {
        // Use the full unread text as the notification body
        let body: String
        if !item.text.isEmpty {
            body = item.text
        } else {
            var bodyParts: [String] = []
            if !item.author.isEmpty { bodyParts.append(item.author) }
            if !item.target.isEmpty { bodyParts.append(item.target) }
            body = bodyParts.isEmpty ? "Máš novú notifikáciu na Birdz" : bodyParts.joined(separator: " · ")
        }

        sendNotification(title: "Birdz", subtitle: "", body: body, badge: badge, delay: delay, trackedItem: item)
    }

    private func sendNotification(title: String, subtitle: String = "", body: String, badge: Int, delay: TimeInterval = 1.0, trackedItem: BirdzScrapedNotificationItem? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        if !subtitle.isEmpty { content.subtitle = subtitle }
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

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(delay, 1.0), repeats: false)
        let request = UNNotificationRequest(
            identifier: "birdz-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("BirdzScraper: ❌ Notification error: \(error.localizedDescription)")
                return
            }

            print("BirdzScraper: ✅ Notification scheduled id=\(request.identifier) title=\(title)")

            // Verify it's pending
            UNUserNotificationCenter.current().getPendingNotificationRequests { pending in
                let ours = pending.filter { $0.identifier.hasPrefix("birdz-") }
                print("BirdzScraper: Pending birdz notifications: \(ours.count)")
            }

            if let trackedItem {
                BirdzNotificationSyncStore.markDelivered(trackedItem)
            }
        }
    }

    private func syncSystemBadge(with unreadBadge: Int) {
        let safeBadge = max(unreadBadge, 0)
        UserDefaults.standard.set(safeBadge, forKey: StorageKeys.unreadBadge)
        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = safeBadge
        }
    }

    private func storeLastContentHash(_ hash: String) {
        lastContentHash = hash
        UserDefaults.standard.set(hash, forKey: StorageKeys.lastContentHash)
    }

    // MARK: - Deep link

    private func navigateToURL(_ urlString: String) {
        guard let wv = webView else { return }
        let escapedURL = urlString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")

        DispatchQueue.main.async {
            wv.evaluateJavaScript("window.location.href = '\(escapedURL)';", completionHandler: nil)
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

// MARK: - WKNavigationDelegate

extension BirdzViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let scraper = scraperWebView, webView === scraper else { return }

        scraperTimeoutWorkItem?.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak scraper] in
            guard let self, let scraper else { return }
            scraper.evaluateJavaScript(BirdzReakcieScrapeJS.source) { _, error in
                self.scraperIsLoading = false
                if let error {
                    print("BirdzScraper: JS error: \(error.localizedDescription)")
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let scraper = scraperWebView, webView === scraper else { return }
        scraperTimeoutWorkItem?.cancel()
        scraperIsLoading = false
        print("BirdzScraper: Load failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let scraper = scraperWebView, webView === scraper else { return }
        scraperTimeoutWorkItem?.cancel()
        scraperIsLoading = false
        print("BirdzScraper: Provisional load failed: \(error.localizedDescription)")
    }
}

// MARK: - WKScriptMessageHandler

extension BirdzViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == scraperHandler, let payload = message.body as? [String: Any] {
            processScrapedItems(payload)
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension BirdzViewController: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound, .badge])
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

// MARK: - JavaScript: Zoom/Safari enhancements

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

        return 'birdz-enhancements-v4';
    })();
    """#
}

// MARK: - JavaScript: Scrape /reakcie/ page for notification items

private enum BirdzReakcieScrapeJS {
    static let source = #"""
    (function() {
        var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.birdzReakcieScraper;
        if (!handler) return 'no-handler';

        function trimText(v) { return (v || '').replace(/\s+/g, ' ').trim(); }

        function simpleHash(str) {
            var hash = 0;
            for (var i = 0; i < str.length; i++) {
                var ch = str.charCodeAt(i);
                hash = ((hash << 5) - hash) + ch;
                hash = hash & hash;
            }
            return hash.toString(36);
        }

        function detectType(text) {
            var v = text.toLowerCase();
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

        function isRedColor(color) {
            var match = (color || '').match(/rgb[a]?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/);
            if (!match) return false;
            var r = parseInt(match[1], 10);
            var g = parseInt(match[2], 10);
            var b = parseInt(match[3], 10);
            return r > 150 && g < 120 && b < 120;
        }

        function isRenderableCandidate(el) {
            if (!el) return false;
            var style = window.getComputedStyle(el);
            return !!style && style.display !== 'none' && style.visibility !== 'hidden' && style.opacity !== '0';
        }

        function isIgnoredContainer(el) {
            if (!el || !el.closest) return false;
            return !!el.closest('.sidebar-wrapper, .sidebar-nav, #header, .header, .header-main, .header_user_menu, nav, header, footer, .sidebar-search, .sidebar-avatar, .logos, .button-more, .button-set');
        }

        function isUnreadContainer(el) {
            if (!el) return false;
            var style = window.getComputedStyle(el);
            var bgColor = style.backgroundColor || '';
            var bgMatch = bgColor.match(/rgb[a]?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/);
            if (!bgMatch) return false;
            var r = parseInt(bgMatch[1], 10);
            var g = parseInt(bgMatch[2], 10);
            var b = parseInt(bgMatch[3], 10);
            return b > 210 && g > 210 && r > 180 && !(r === 255 && g === 255 && b === 255);
        }

        function extractExactUnreadText(el) {
            if (!el) return '';

            var parts = [];
            var nodes = el.querySelectorAll('*');

            for (var i = 0; i < nodes.length; i++) {
                var node = nodes[i];
                if (node.children && node.children.length > 0) {
                    var hasRedChild = false;
                    for (var k = 0; k < node.children.length; k++) {
                        if (isRedColor(window.getComputedStyle(node.children[k]).color || '')) {
                            hasRedChild = true;
                            break;
                        }
                    }
                    if (hasRedChild) continue;
                }

                var style = window.getComputedStyle(node);
                var nodeColor = style.color || '';

                if (isRedColor(nodeColor)) {
                    var text = trimText(node.textContent || '');
                    if (text.length > 1) {
                        parts.push(text);
                    }
                }
            }

            if (parts.length === 0) {
                var bolds = el.querySelectorAll('strong, b');
                for (var b = 0; b < bolds.length; b++) {
                    var bText = trimText(bolds[b].textContent || '');
                    if (bText.length > 1) parts.push(bText);
                }
            }

            if (parts.length === 0) return '';

            var unique = [];
            for (var u = 0; u < parts.length; u++) {
                var isDup = false;
                for (var v = 0; v < parts.length; v++) {
                    if (u !== v && parts[v].length > parts[u].length && parts[v].indexOf(parts[u]) > -1) {
                        isDup = true;
                        break;
                    }
                }
                if (!isDup && unique.indexOf(parts[u]) === -1) {
                    unique.push(parts[u]);
                }
            }

            return trimText(unique.join(' '));
        }

        function isSecretMessageText(text) {
            return /tajn[ée]?\s+správ|tajn[ée]?\s+sprav/i.test(text || '');
        }

        function looksLikeReactionText(text) {
            return /(\d+\s+nov[ýy]ch?\s+koment|ťa\s+označil|ta\s+oznacil|sleduje|reagoval|komentoval|okomentoval)/i.test(text || '');
        }

        var pageRoot = document.querySelector('#page') ||
            document.querySelector('.page-content-wrapper') ||
            document.querySelector('main') ||
            document.body;
        var rawText = trimText(pageRoot ? (pageRoot.innerText || pageRoot.textContent || '') : '');
        var items = [];
        var unreadBadge = 0;
        var rows = pageRoot.querySelectorAll('li, tr, .item, [class*="notif"], [class*="reakc"], div[class*="row"], .comment, article');

        for (var i = 0; i < rows.length && items.length < 40; i++) {
            var el = rows[i];
            if (!isRenderableCandidate(el) || isIgnoredContainer(el)) continue;

            var txt = trimText(el.innerText || el.textContent || '');
            if (txt.length < 8 || txt.length > 500) continue;
            if (/^(Fórum|Statusy|Blogy|Obrázky|Ľudia|Nastavenia|Prihlás|Odhlás|Hľadaj|Pridaj|Roleta)/i.test(txt)) continue;
            if (isSecretMessageText(txt)) continue;

            var exactUnreadText = extractExactUnreadText(el);
            if (isSecretMessageText(exactUnreadText)) continue;

            var isUnread = !!exactUnreadText || isUnreadContainer(el);
            var candidateText = exactUnreadText || txt.replace(/🗑️?/g, '').replace(/\s+/g, ' ').trim();
            if (!candidateText) continue;
            if (isSecretMessageText(candidateText)) continue;

            // Skip zero-count items
            if (/^0\s+nov[ýy]ch?\s+koment/i.test(candidateText)) continue;

            // candidateText itself must contain a reaction pattern
            var hasReactionPattern = looksLikeReactionText(candidateText);
            if (!hasReactionPattern) continue;

            var links = el.querySelectorAll('a');
            var author = '';
            var target = '';
            var itemLink = '';
            for (var j = 0; j < links.length; j++) {
                var linkText = trimText(links[j].textContent);
                var href = links[j].href || '';
                if (linkText.length > 1 && linkText.length < 50) {
                    if (!author) author = linkText;
                    else if (!target) target = linkText;
                }
                if (!itemLink && href && href.indexOf('birdz.sk') > -1 && href !== 'https://www.birdz.sk/reakcie/') {
                    itemLink = href;
                }
            }
            if (!itemLink && links.length > 0) {
                for (var lk = 0; lk < links.length; lk++) {
                    var h = links[lk].href || '';
                    if (h && h.indexOf('birdz.sk') > -1) { itemLink = h; break; }
                }
            }

            var timeEl = el.querySelector('time, [class*="time"], [class*="date"], .ago, small');
            var time = timeEl ? trimText(timeEl.textContent) : '';

            items.push({
                type: detectType(candidateText),
                author: author,
                text: (exactUnreadText || candidateText).substring(0, 300),
                target: target,
                time: time
            });

            if (isUnread && exactUnreadText) {
                var numMatch = candidateText.match(/(\d+)\s+nov[ýy]ch?\s+koment/i);
                if (numMatch) {
                    unreadBadge += parseInt(numMatch[1], 10) || 0;
                } else if (/(ťa\s+označil|ta\s+oznacil|sleduje|reagoval|komentoval|okomentoval)/i.test(candidateText)) {
                    unreadBadge += 1;
                }
            }
        }

        if (unreadBadge === 0) {
            var tabMatch = rawText.match(/neprečítan[ée]\s+(\d+)/i);
            if (tabMatch) {
                unreadBadge = parseInt(tabMatch[1], 10) || 0;
            }
        }

        var contentHash = simpleHash(rawText);

        handler.postMessage({
            contentHash: contentHash,
            items: items,
            totalCount: items.length,
            unreadBadge: unreadBadge,
            rawText: rawText.slice(0, 500)
        });
        return 'birdz-reakcie-scraped';
    })();
    """#
}
