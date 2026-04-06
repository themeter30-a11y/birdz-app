import UIKit
import Capacitor
import WebKit
import UserNotifications

final class BirdzViewController: CAPBridgeViewController {

    // MARK: - Properties

    private var pollTimer: Timer?
    private var refreshControl: UIRefreshControl?
    private var didInstallScripts = false
    private var lastAppliedTopInset: CGFloat = 0

    // Scraper: hidden webview that loads /reakcie/ every 5s
    private var scraperWebView: WKWebView?
    private let scraperHandler = "birdzReakcieScraper"
    private var lastContentHash: String = ""
    private var isFirstScrape = true
    private var scraperIsLoading = false
    private var pendingBadgeCount: Int = 0

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
        scraperWebView?.configuration.userContentController.removeScriptMessageHandler(forName: scraperHandler)
    }

    // MARK: - Lifecycle

    @objc private func handleAppDidBecomeActive() {
        configureWebViewIfNeeded()
        startPolling()
    }

    @objc private func handleAppWillResignActive() {
        // Keep polling even in background
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

        // Pinch-to-zoom backup
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        wv.scrollView.addGestureRecognizer(pinch)

        // Pull-to-refresh
        if refreshControl == nil {
            let rc = UIRefreshControl()
            rc.tintColor = .systemRed
            rc.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
            wv.scrollView.addSubview(rc)
            refreshControl = rc
        }

        // Inject zoom-fix JS
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

    // MARK: - Hidden Scraper WebView (polls /reakcie/ every 5s)

    private func setupScraperWebView() {
        let config = WKWebViewConfiguration()
        // Share cookies/session with main webview so we see logged-in content
        config.processPool = webView?.configuration.processPool ?? WKProcessPool()
        config.websiteDataStore = webView?.configuration.websiteDataStore ?? .default()
        config.userContentController.add(self, name: scraperHandler)

        let scraper = WKWebView(frame: .zero, configuration: config)
        scraper.isHidden = true
        view.addSubview(scraper)
        scraperWebView = scraper
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.loadReakciePage()
        }
        // First scrape after 2s to let session load
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.loadReakciePage()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Load /reakcie/ in hidden webview, then inject scraping JS after page loads
    private func loadReakciePage() {
        guard !scraperIsLoading else { return }
        guard let scraper = scraperWebView,
              let url = URL(string: "https://www.birdz.sk/reakcie/") else { return }

        scraperIsLoading = true
        scraper.load(URLRequest(url: url))

        // Wait for page to load, then inject scraper JS
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.scraperWebView?.evaluateJavaScript(BirdzReakcieScrapeJS.source) { _, error in
                self?.scraperIsLoading = false
                if let error = error {
                    print("BirdzScraper: JS error: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Process scraped data from /reakcie/

    private func processScrapedItems(_ payload: [String: Any]) {
        let contentHash = payload["contentHash"] as? String ?? ""
        let items = payload["items"] as? [[String: Any]] ?? []

        // First run: just store the state, don't notify
        if isFirstScrape {
            lastContentHash = contentHash
            isFirstScrape = false
            // Reset badge when app opens
            pendingBadgeCount = 0
            DispatchQueue.main.async {
                UIApplication.shared.applicationIconBadgeNumber = 0
            }
            print("BirdzScraper: Initial state stored, hash=\(contentHash)")
            return
        }

        // No change — do nothing
        guard contentHash != lastContentHash else { return }

        print("BirdzScraper: Change detected! old=\(lastContentHash) new=\(contentHash)")

        // Skip notification if page says "0 nových komentárov"
        let rawText = (payload["rawText"] as? String ?? "").lowercased()
        let skip = rawText.contains("0 nových komment") || rawText.contains("0 nových koment") || rawText.contains("0 novych koment")

        if !skip {
            // Increment badge by 1 for each real change
            pendingBadgeCount += 1

            DispatchQueue.main.async {
                UIApplication.shared.applicationIconBadgeNumber = self.pendingBadgeCount
            }

            if let topItem = items.first {
                let type = topItem["type"] as? String ?? "Upozornenie"
                let author = topItem["author"] as? String ?? ""
                let text = topItem["text"] as? String ?? ""
                let target = topItem["target"] as? String ?? ""
                let time = topItem["time"] as? String ?? ""

                let title: String
                if !author.isEmpty {
                    title = "Birdz – \(type) od \(author)"
                } else {
                    title = "Birdz – \(type)"
                }

                var bodyParts: [String] = []
                if !text.isEmpty { bodyParts.append(text) }
                if !target.isEmpty { bodyParts.append("➜ \(target)") }
                if !time.isEmpty { bodyParts.append("🕐 \(time)") }

                let body = bodyParts.isEmpty ? "Máš novú notifikáciu na Birdz" : bodyParts.joined(separator: "\n")

                sendNotification(title: title, subtitle: type, body: body, badge: pendingBadgeCount)
            } else {
                sendNotification(title: "Birdz", subtitle: "Nová aktivita", body: "Máš novú aktivitu v reakciách", badge: pendingBadgeCount)
            }
        } else {
            print("BirdzScraper: Skipping notification – 0 nových komentárov")
        }

        lastContentHash = contentHash
    }

    // MARK: - iOS Notifications

    private func sendNotification(title: String, subtitle: String = "", body: String, badge: Int) {
        let content = UNMutableNotificationContent()
        content.title = title
        if !subtitle.isEmpty { content.subtitle = subtitle }
        content.body = body
        content.sound = .default
        content.badge = NSNumber(value: badge)
        content.userInfo = ["deepLink": "https://www.birdz.sk/reakcie/"]
        content.threadIdentifier = "birdz-reakcie"
        content.categoryIdentifier = "BIRDZ_REAKCIA"

        // Attach Birdz icon to the notification
        if let iconURL = Bundle.main.url(forResource: "birdz_notification", withExtension: "png") {
            do {
                let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                let tmpFile = tmpDir.appendingPathComponent("birdz_notification.png")
                try FileManager.default.copyItem(at: iconURL, to: tmpFile)
                let attachment = try UNNotificationAttachment(identifier: "birdz-icon", url: tmpFile, options: nil)
                content.attachments = [attachment]
            } catch {
                print("BirdzScraper: Attachment error: \(error.localizedDescription)")
            }
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        let request = UNNotificationRequest(
            identifier: "birdz-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("BirdzScraper: Notification error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Deep link

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

        // Scrape notification items
        var items = [];
        var rows = document.querySelectorAll('li, tr, .item, [class*="notif"], [class*="reakc"], div[class*="row"], .comment, article');
        for (var i = 0; i < rows.length && items.length < 10; i++) {
            var el = rows[i];
            var txt = trimText(el.innerText || el.textContent || '');
            if (txt.length < 5 || txt.length > 500) continue;

            var links = el.querySelectorAll('a');
            var author = '';
            var target = '';
            for (var j = 0; j < links.length; j++) {
                var linkText = trimText(links[j].textContent);
                if (linkText.length > 1 && linkText.length < 50) {
                    if (!author) author = linkText;
                    else if (!target) target = linkText;
                }
            }

            var timeEl = el.querySelector('time, [class*="time"], [class*="date"], .ago, small');
            var time = timeEl ? trimText(timeEl.textContent) : '';

            items.push({
                type: detectType(txt),
                author: author,
                text: txt.substring(0, 200),
                target: target,
                time: time
            });
        }

        // Badge
        var unreadBadge = 0;
        var badgeEls = document.querySelectorAll('.badge, [class*="badge"], [class*="count"], [class*="notif"] span, .num, [class*="num"]');
        for (var b = 0; b < badgeEls.length; b++) {
            var badgeText = trimText(badgeEls[b].textContent);
            var parsed = parseInt(badgeText, 10);
            if (!isNaN(parsed) && parsed > 0 && parsed < 1000) {
                unreadBadge = parsed;
                break;
            }
        }
        if (unreadBadge === 0) unreadBadge = items.length;

        var rawText = trimText(document.body ? document.body.innerText : '');
        var contentHash = simpleHash(rawText);

        handler.postMessage({ contentHash: contentHash, items: items, totalCount: items.length, unreadBadge: unreadBadge, rawText: rawText.slice(0, 500) });
        return 'birdz-reakcie-scraped';
    })();
    """#
}
