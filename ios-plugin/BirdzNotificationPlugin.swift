import Foundation
import UIKit
import UserNotifications
import WebKit

class BirdzNotificationMonitor: NSObject {
    
    static let shared = BirdzNotificationMonitor()
    
    private var webView: WKWebView?
    private var timer: Timer?
    private var lastBadgeCount: Int = -1
    private var lastNotificationDetails: [String: Int] = [:]
    
    // JavaScript that scrapes notification details including message previews
    // Runs every 5 seconds for reliable detection
    private let scrapeScript = """
    (function() {
        var result = { totalCount: 0, details: [] };
        
        // 1. Get total badge count from header
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
        
        // Fallback: scan header for any small badge-like element
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
                            if ((bg.indexOf('rgb') > -1 && bg !== 'rgba(0, 0, 0, 0)') || borderRadius > 5) {
                                result.totalCount = parseInt(txt);
                                break;
                            }
                        }
                    }
                }
            }
        }
        
        // 2. Try to extract detailed notification info with previews
        // Look for notification list items (when dropdown/menu is open or in notification page)
        var notifContainers = document.querySelectorAll(
            '.notifications-list li, .notification-item, [class*="notif"] li, ' +
            '.dropdown-menu li, .menu-dropdown li, [class*="dropdown"] li, ' +
            '.list-group-item, [class*="notification"]'
        );
        
        for (var n = 0; n < notifContainers.length; n++) {
            var container = notifContainers[n];
            var fullText = container.textContent || '';
            
            // Try to find sender name (usually bold or in a link)
            var senderEl = container.querySelector('strong, b, .username, [class*="user"], [class*="name"], a[href*="profil"]');
            var sender = senderEl ? senderEl.textContent.trim() : '';
            
            // Try to find the message/preview text
            var previewEl = container.querySelector('p, .text, .message, [class*="text"], [class*="preview"], [class*="body"], .description, em, span:not(.badge)');
            var preview = previewEl ? previewEl.textContent.trim() : '';
            
            // Determine notification type
            var type = 'Upozornenie';
            if (fullText.indexOf('Tajn') > -1 || fullText.indexOf('správ') > -1 || fullText.indexOf('Správ') > -1) {
                type = 'Tajná správa';
            } else if (fullText.indexOf('Reakci') > -1 || fullText.indexOf('reakci') > -1) {
                type = 'Reakcia na status';
            } else if (fullText.indexOf('koment') > -1 || fullText.indexOf('Koment') > -1) {
                type = 'Komentár';
            } else if (fullText.indexOf('sleduj') > -1 || fullText.indexOf('Sleduj') > -1) {
                type = 'Nový sledovateľ';
            } else if (fullText.indexOf('označil') > -1 || fullText.indexOf('Označil') > -1) {
                type = 'Označenie';
            }
            
            if (sender || preview) {
                result.details.push({
                    type: type,
                    sender: sender,
                    preview: preview.substring(0, 200),
                    count: 1
                });
            }
        }
        
        // 3. Fallback: scan menu items for notification counts by type
        if (result.details.length === 0 && result.totalCount > 0) {
            var menuItems = document.querySelectorAll('li, .menu-item, [class*="notif"] a, [class*="menu"] a');
            for (var k = 0; k < menuItems.length; k++) {
                var item = menuItems[k];
                var itemText = item.textContent || '';
                var itemBadge = item.querySelector('.badge, [class*="count"], [class*="num"]');
                
                if (itemText.indexOf('Tajn') > -1 || itemText.indexOf('správ') > -1 || itemText.indexOf('Správ') > -1) {
                    var c = 0;
                    if (itemBadge) c = parseInt(itemBadge.textContent.trim()) || 0;
                    else {
                        var match = itemText.match(/(\\d+)/);
                        if (match) c = parseInt(match[1]);
                    }
                    if (c > 0) result.details.push({ type: 'Tajná správa', sender: '', preview: '', count: c });
                }
                if (itemText.indexOf('Reakci') > -1 || itemText.indexOf('reakci') > -1) {
                    var r = 0;
                    if (itemBadge) r = parseInt(itemBadge.textContent.trim()) || 0;
                    else {
                        var rMatch = itemText.match(/(\\d+)/);
                        if (rMatch) r = parseInt(rMatch[1]);
                    }
                    if (r > 0) result.details.push({ type: 'Reakcia na status', sender: '', preview: '', count: r });
                }
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
        
        // Poll every 5 seconds for reliable, fast detection
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkForNotifications()
        }
        
        // Initial check after page loads
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.checkForNotifications()
        }
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
    
    private func checkForNotifications() {
        guard let webView = webView else { return }
        DispatchQueue.main.async {
            webView.evaluateJavaScript(self.scrapeScript) { [weak self] result, error in
                if let jsonString = result as? String {
                    self?.processResult(jsonString: jsonString)
                }
                if let error = error {
                    print("BirdzMonitor: JS error: \(error.localizedDescription)")
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
        
        // Always update app badge icon
        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = totalCount
        }
        
        print("BirdzMonitor: Badge = \(totalCount), previous = \(self.lastBadgeCount)")
        
        // Send notification if count increased
        if totalCount > self.lastBadgeCount && self.lastBadgeCount >= 0 {
            let newNotifs = totalCount - self.lastBadgeCount
            
            if !details.isEmpty {
                // Send detailed notifications
                for detail in details {
                    let type = detail["type"] as? String ?? "Upozornenie"
                    let sender = detail["sender"] as? String ?? ""
                    let preview = detail["preview"] as? String ?? ""
                    let count = detail["count"] as? Int ?? 1
                    
                    let previousCount = self.lastNotificationDetails[type] ?? 0
                    if count > previousCount {
                        var body = ""
                        if !sender.isEmpty && !preview.isEmpty {
                            body = "\(sender): \(preview)"
                        } else if !sender.isEmpty {
                            body = "Od: \(sender)"
                        } else if !preview.isEmpty {
                            body = preview
                        } else {
                            let diff = count - previousCount
                            body = diff == 1
                                ? "Máš novú notifikáciu: \(type)"
                                : "Máš \(diff) nových: \(type)"
                        }
                        
                        self.sendNotification(
                            title: "Birdz – \(type)",
                            body: body,
                            badge: totalCount
                        )
                    }
                }
            } else {
                // Generic notification
                self.sendNotification(
                    title: "Birdz",
                    body: newNotifs == 1
                        ? "Máš novú notifikáciu"
                        : "Máš \(newNotifs) nových notifikácií",
                    badge: totalCount
                )
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
                print("BirdzMonitor: Notification error: \(error)")
            } else {
                print("BirdzMonitor: Sent – \(title): \(body)")
            }
        }
    }
}
