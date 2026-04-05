import Foundation
import UIKit
import UserNotifications
import WebKit

class BirdzNotificationMonitor: NSObject {
    
    static let shared = BirdzNotificationMonitor()
    
    private var webView: WKWebView?
    private var timer: Timer?
    private var lastBadgeCount: Int = -1  // Start at -1 so first check always updates
    private var lastNotificationDetails: [String: Int] = [:]
    
    // JavaScript that monitors the notification badge on birdz.sk
    // Uses MutationObserver for instant detection + polling fallback
    private let setupObserverScript = """
    (function() {
        if (window._birdzObserverActive) return 'already_active';
        window._birdzObserverActive = true;
        window._birdzLastCount = -1;
        
        function checkBadge() {
            var result = { totalCount: 0, details: [] };
            
            // Strategy 1: Look for badge elements with common selectors
            var selectors = [
                '.button-more .badge',
                '.header_user_avatar .badge', 
                'a.button-more span',
                '.badge',
                '[class*="notif"] .badge',
                '.header .badge'
            ];
            
            for (var s = 0; s < selectors.length; s++) {
                var els = document.querySelectorAll(selectors[s]);
                for (var i = 0; i < els.length; i++) {
                    var text = els[i].textContent.trim();
                    if (/^\\d+$/.test(text) && parseInt(text) > 0) {
                        result.totalCount = parseInt(text);
                        break;
                    }
                }
                if (result.totalCount > 0) break;
            }
            
            // Strategy 2: Scan header for any small red/colored element with a number
            if (result.totalCount === 0) {
                var header = document.querySelector('header, .header, #header, .header-main, nav');
                if (header) {
                    var allEls = header.querySelectorAll('span, div, a, sup, b, strong, em, i');
                    for (var j = 0; j < allEls.length; j++) {
                        var el = allEls[j];
                        var txt = el.textContent.trim();
                        if (/^\\d+$/.test(txt) && parseInt(txt) > 0 && parseInt(txt) < 1000) {
                            var rect = el.getBoundingClientRect();
                            if (rect.width > 0 && rect.width < 50 && rect.height < 50) {
                                var style = window.getComputedStyle(el);
                                var bg = style.backgroundColor;
                                var borderRadius = parseFloat(style.borderRadius);
                                // Red-ish background or round shape = likely a badge
                                if (bg.indexOf('rgb') > -1 && bg !== 'rgba(0, 0, 0, 0)' || borderRadius > 5) {
                                    result.totalCount = parseInt(txt);
                                    break;
                                }
                            }
                        }
                    }
                }
            }
            
            // Try to get notification type details
            var menuItems = document.querySelectorAll('li, .menu-item, [class*="notif"] a, [class*="menu"] a');
            for (var k = 0; k < menuItems.length; k++) {
                var item = menuItems[k];
                var itemText = item.textContent || '';
                var itemBadge = item.querySelector('.badge, [class*="count"], [class*="num"]');
                
                if (itemText.indexOf('Tajn') > -1 || itemText.indexOf('správ') > -1 || itemText.indexOf('Správ') > -1) {
                    var count = 0;
                    if (itemBadge) count = parseInt(itemBadge.textContent.trim()) || 0;
                    else {
                        var match = itemText.match(/(\\d+)/);
                        if (match) count = parseInt(match[1]);
                    }
                    if (count > 0) result.details.push({ type: 'Tajná správa', count: count });
                }
                if (itemText.indexOf('Reakci') > -1 || itemText.indexOf('reakci') > -1) {
                    var rCount = 0;
                    if (itemBadge) rCount = parseInt(itemBadge.textContent.trim()) || 0;
                    else {
                        var rMatch = itemText.match(/(\\d+)/);
                        if (rMatch) rCount = parseInt(rMatch[1]);
                    }
                    if (rCount > 0) result.details.push({ type: 'Reakcia', count: rCount });
                }
            }
            
            // Notify native side if count changed
            if (result.totalCount !== window._birdzLastCount) {
                window._birdzLastCount = result.totalCount;
                try {
                    window.webkit.messageHandlers.birdzBadge.postMessage(JSON.stringify(result));
                } catch(e) {}
            }
            
            return JSON.stringify(result);
        }
        
        // Set up MutationObserver for instant detection
        var observer = new MutationObserver(function() {
            checkBadge();
        });
        observer.observe(document.body, { 
            childList: true, 
            subtree: true, 
            characterData: true,
            attributes: true,
            attributeFilter: ['class', 'style']
        });
        
        // Also poll every 10 seconds as fallback
        setInterval(checkBadge, 10000);
        
        // Initial check
        return checkBadge();
    })();
    """;
    
    // Simple poll script for timer-based checking
    private let pollScript = """
    (function() {
        var result = { totalCount: 0, details: [] };
        var selectors = ['.button-more .badge', '.header_user_avatar .badge', 'a.button-more span', '.badge', '[class*="notif"] .badge', '.header .badge'];
        for (var s = 0; s < selectors.length; s++) {
            var els = document.querySelectorAll(selectors[s]);
            for (var i = 0; i < els.length; i++) {
                var text = els[i].textContent.trim();
                if (/^\\d+$/.test(text) && parseInt(text) > 0) {
                    result.totalCount = parseInt(text);
                    break;
                }
            }
            if (result.totalCount > 0) break;
        }
        if (result.totalCount === 0) {
            var header = document.querySelector('header, .header, #header, .header-main, nav');
            if (header) {
                var allEls = header.querySelectorAll('span, div, a, sup, b, strong, em, i');
                for (var j = 0; j < allEls.length; j++) {
                    var el = allEls[j];
                    var txt = el.textContent.trim();
                    if (/^\\d+$/.test(txt) && parseInt(txt) > 0 && parseInt(txt) < 1000) {
                        var rect = el.getBoundingClientRect();
                        if (rect.width > 0 && rect.width < 50 && rect.height < 50) {
                            result.totalCount = parseInt(txt);
                            break;
                        }
                    }
                }
            }
        }
        var menuItems = document.querySelectorAll('li, .menu-item');
        for (var k = 0; k < menuItems.length; k++) {
            var item = menuItems[k];
            var itemText = item.textContent || '';
            var itemBadge = item.querySelector('.badge, [class*="count"]');
            if (itemText.indexOf('Tajn') > -1 || itemText.indexOf('správ') > -1) {
                var c = 0;
                if (itemBadge) c = parseInt(itemBadge.textContent.trim()) || 0;
                if (c > 0) result.details.push({ type: 'Tajná správa', count: c });
            }
            if (itemText.indexOf('Reakci') > -1) {
                var r = 0;
                if (itemBadge) r = parseInt(itemBadge.textContent.trim()) || 0;
                if (r > 0) result.details.push({ type: 'Reakcia', count: r });
            }
        }
        return JSON.stringify(result);
    })();
    """;
    
    func startMonitoring(webView: WKWebView) {
        self.webView = webView
        
        // Request notification permissions
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if granted {
                print("BirdzMonitor: Notification permission granted")
            } else {
                print("BirdzMonitor: Notification permission denied: \(String(describing: error))")
            }
        }
        
        // Register message handler for MutationObserver callbacks
        webView.configuration.userContentController.add(self, name: "birdzBadge")
        
        // Set up the MutationObserver after page loads
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.setupObserver()
        }
        
        // Also poll every 15 seconds as backup
        timer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.checkForNotifications()
        }
        
        // Re-setup observer when page navigates
        webView.addObserver(self, forKeyPath: "URL", options: .new, context: nil)
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "URL" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.setupObserver()
            }
        }
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        webView?.removeObserver(self, forKeyPath: "URL")
    }
    
    private func setupObserver() {
        guard let webView = webView else { return }
        DispatchQueue.main.async {
            webView.evaluateJavaScript(self.setupObserverScript) { [weak self] result, error in
                if let jsonString = result as? String, jsonString != "already_active" {
                    self?.processResult(jsonString: jsonString)
                }
                if let error = error {
                    print("BirdzMonitor: Observer setup error: \(error)")
                }
            }
        }
    }
    
    private func checkForNotifications() {
        guard let webView = webView else { return }
        DispatchQueue.main.async {
            webView.evaluateJavaScript(self.pollScript) { [weak self] result, error in
                if let jsonString = result as? String {
                    self?.processResult(jsonString: jsonString)
                }
            }
        }
    }
    
    private func processResult(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let totalCount = json["totalCount"] as? Int else {
            return
        }
        
        let details = json["details"] as? [[String: Any]] ?? []
        
        // Always update app badge
        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = totalCount
        }
        
        print("BirdzMonitor: Badge count = \(totalCount), last = \(self.lastBadgeCount)")
        
        // Check if count increased (new notification arrived)
        if totalCount > self.lastBadgeCount && self.lastBadgeCount >= 0 {
            if details.isEmpty {
                self.sendNotification(
                    title: "Birdz",
                    body: "Máš \(totalCount) neprečítaných notifikácií",
                    badge: totalCount
                )
            } else {
                for detail in details {
                    if let type = detail["type"] as? String,
                       let count = detail["count"] as? Int,
                       count > 0 {
                        let previousCount = self.lastNotificationDetails[type] ?? 0
                        if count > previousCount {
                            let newCount = count - previousCount
                            self.sendNotification(
                                title: "Birdz - \(type)",
                                body: newCount == 1
                                    ? "Máš novú: \(type)"
                                    : "Máš \(newCount) nových: \(type)",
                                badge: totalCount
                            )
                        }
                    }
                }
            }
        }
        
        self.lastBadgeCount = totalCount
        
        // Update detail tracking
        self.lastNotificationDetails = [:]
        for detail in details {
            if let type = detail["type"] as? String,
               let count = detail["count"] as? Int {
                self.lastNotificationDetails[type] = count
            }
        }
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
                print("BirdzMonitor: Error sending notification: \(error)")
            } else {
                print("BirdzMonitor: Notification sent - \(title): \(body)")
            }
        }
    }
}

// MARK: - WKScriptMessageHandler for MutationObserver callbacks
extension BirdzNotificationMonitor: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "birdzBadge", let jsonString = message.body as? String {
            print("BirdzMonitor: MutationObserver detected change")
            processResult(jsonString: jsonString)
        }
    }
}
