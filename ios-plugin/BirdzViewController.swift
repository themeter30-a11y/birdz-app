import UIKit
import Capacitor
import WebKit
import UserNotifications

// MARK: - Custom ViewController – toto je JEDINÝ súbor, ktorý potrebuješ
// Nahrádza štandardný CAPBridgeViewController a pridáva:
// 1. Safe area (obsah pod stavovým riadkom)
// 2. Pinch-to-zoom
// 3. Swipe späť/vpred
// 4. Pull-to-refresh
// 5. Dlhý stisk na obrázkoch/linkoch
// 6. Badge na ikone appky
// 7. iOS notifikácie s typom a náhľadom textu
// 8. 5-sekundový polling

class BirdzViewController: CAPBridgeViewController {

    private var pollTimer: Timer?
    private var lastBadgeCount: Int = -1
    private var lastSignatures = Set<String>()
    private var refreshControl: UIRefreshControl?
    private let handlerName = "birdzNotificationMonitor"

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let wv = webView else { return }

        // 1. Safe area – obsah začína pod stavovým riadkom
        wv.scrollView.contentInsetAdjustmentBehavior = .always

        // 2. Pinch-to-zoom
        wv.scrollView.minimumZoomScale = 1.0
        wv.scrollView.maximumZoomScale = 5.0
        wv.scrollView.bouncesZoom = true

        // 3. Swipe späť/vpred
        wv.allowsBackForwardNavigationGestures = true

        // 4. Dlhý stisk – náhľad linkov, uloženie obrázkov
        wv.allowsLinkPreview = true

        // 5. Bouncy scroll
        wv.scrollView.bounces = true
        wv.scrollView.alwaysBounceVertical = true

        // 6. Pull-to-refresh
        let rc = UIRefreshControl()
        rc.tintColor = .systemRed
        rc.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        wv.scrollView.addSubview(rc)
        refreshControl = rc

        // 7. JS bridge pre notifikácie
        let controller = wv.configuration.userContentController
        controller.removeScriptMessageHandler(forName: handlerName)
        controller.add(self, name: handlerName)

        // 8. Povolenie notifikácií
        requestNotificationPermission()

        // 9. Injektuj JS na povolenie zoomu (stránka to môže blokovať cez viewport meta)
        injectZoomFix(into: wv)

        // 10. Spusti polling
        startPolling()

        print("BirdzViewController: Všetko nakonfigurované ✅")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Pull to refresh

    @objc private func handleRefresh() {
        webView?.reload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshControl?.endRefreshing()
        }
    }

    // MARK: - Zoom fix

    private func injectZoomFix(into wv: WKWebView) {
        let js = """
        (function() {
            var meta = document.querySelector('meta[name="viewport"]');
            if (meta) {
                var c = meta.getAttribute('content') || '';
                c = c.replace(/user-scalable\\s*=\\s*no/gi, 'user-scalable=yes');
                c = c.replace(/maximum-scale\\s*=\\s*[\\d.]+/gi, 'maximum-scale=5.0');
                meta.setAttribute('content', c);
            }
        })();
        """
        let script = WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        wv.configuration.userContentController.addUserScript(script)
    }

    // MARK: - Notification permission

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                    print("BirdzViewController: Notifikácie povolené: \(granted)")
                }
            }
        }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.runScrape()
        }
        // Prvý beh po 2 sekundách (nech sa stránka načíta)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.runScrape()
        }
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

    // MARK: - Process scraped data

    private func processPayload(_ payload: [String: Any]) {
        let totalCount = payload["totalCount"] as? Int ?? 0
        let details = payload["details"] as? [[String: Any]] ?? []

        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = totalCount
        }

        print("BirdzViewController: Badge=\(totalCount) prev=\(lastBadgeCount) details=\(details.count)")

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

    private func sig(_ d: [String: Any]) -> String {
        let t = d["type"] as? String ?? ""
        let s = d["sender"] as? String ?? ""
        let p = d["preview"] as? String ?? ""
        return [t, s, p].joined(separator: "|")
    }

    // MARK: - iOS Notifications

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
            } else {
                print("BirdzViewController: Odoslané – \(title): \(body)")
            }
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

// MARK: - JavaScript scraping payload

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

        function pickPreview(c) {
            var sels = ['.message','.preview','.description','.text','[class*="message"]','[class*="preview"]','p','span'];
            for (var i = 0; i < sels.length; i++) {
                var el = c.querySelector(sels[i]);
                var t = trimText(el && el.textContent);
                if (t && !/^\d+$/.test(t)) return t.slice(0, 220);
            }
            return trimText(c.textContent).slice(0, 220);
        }

        function pickSender(c) {
            var sels = ['.username','.user','.name','[class*="username"]','[class*="sender"]','strong','b','a[href*="profil"]'];
            for (var i = 0; i < sels.length; i++) {
                var el = c.querySelector(sels[i]);
                var t = trimText(el && el.textContent);
                if (t && !/^\d+$/.test(t)) return t.slice(0, 80);
            }
            return '';
        }

        function extractDetails(root) {
            var containers = root.querySelectorAll('.notifications-list li, .notification-item, [class*="notif"] li, [class*="notification"] li, .dropdown-menu li, .list-group-item, [class*="notification"]');
            var details = [], seen = {};
            for (var i = 0; i < containers.length; i++) {
                var c = containers[i];
                var ft = trimText(c.textContent);
                if (!ft) continue;
                var d = { type: detectType(ft), sender: pickSender(c), preview: pickPreview(c), count: 1 };
                var sig = [d.type, d.sender, d.preview].join('|');
                if (seen[sig]) continue;
                seen[sig] = true;
                details.push(d);
                if (details.length >= 10) break;
            }
            return details;
        }

        var snapshot = {
            totalCount: extractTotalCount(document),
            details: extractDetails(document),
            sourceUrl: window.location.href
        };

        handler.postMessage(snapshot);
        return 'birdz-monitor-ran';
    })();
    """#
}