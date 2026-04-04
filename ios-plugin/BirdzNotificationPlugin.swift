import Foundation
import UIKit
import UserNotifications
import WebKit

class BirdzNotificationMonitor: NSObject {
    
    static let shared = BirdzNotificationMonitor()
    
    private var webView: WKWebView?
    private var timer: Timer?
    private var lastBadgeCount: Int = 0
    private var lastNotificationDetails: [String: Int] = [:]
    
    // JavaScript that monitors the notification badge on birdz.sk
    // It looks for the red badge number on the profile avatar in the header
    private let monitorScript = """
    (function() {
        var result = { totalCount: 0, details: [] };
        
        // Look for badge/count elements near the header avatar
        // The badge is a red circle with a number on the profile picture
        var badges = document.querySelectorAll('.button-more .badge, .header_user_avatar .badge, .button-more [class*="count"], .button-more [class*="notif"], .header_user_avatar + .badge, span.badge');
        
        // Also try looking for any small red circle with a number in the header
        if (badges.length === 0) {
            var headerEl = document.querySelector('.header-main, #header, header');
            if (headerEl) {
                var allSpans = headerEl.querySelectorAll('span, div, a');
                for (var i = 0; i < allSpans.length; i++) {
                    var el = allSpans[i];
                    var text = el.textContent.trim();
                    var style = window.getComputedStyle(el);
                    // Look for small elements with numbers and red/badge-like styling
                    if (/^\\d+$/.test(text) && parseInt(text) > 0) {
                        var bgColor = style.backgroundColor;
                        var isRed = bgColor.indexOf('255') > -1 || bgColor.indexOf('red') > -1 || el.className.indexOf('badge') > -1 || el.className.indexOf('count') > -1;
                        var isSmall = el.offsetWidth < 40 && el.offsetHeight < 40;
                        if ((isRed || isSmall) && el.offsetWidth > 0) {
                            result.totalCount = parseInt(text);
                            break;
                        }
                    }
                }
            }
        } else {
            for (var j = 0; j < badges.length; j++) {
                var badgeText = badges[j].textContent.trim();
                if (/^\\d+$/.test(badgeText)) {
                    result.totalCount = parseInt(badgeText);
                    break;
                }
            }
        }
        
        // Try to get notification details from the dropdown menu
        var menuItems = document.querySelectorAll('.header_user_menu li, .div-more li, #sidebar li');
        for (var k = 0; k < menuItems.length; k++) {
            var item = menuItems[k];
            var itemText = item.textContent.trim();
            var itemBadge = item.querySelector('.badge, [class*="count"]');
            
            // Look for "Tajné správy" or "Reakcie" with counts
            if (itemText.indexOf('Tajn') > -1 || itemText.indexOf('správ') > -1) {
                var count = 0;
                if (itemBadge) count = parseInt(itemBadge.textContent.trim()) || 0;
                else {
                    var match = itemText.match(/(\\d+)/);
                    if (match) count = parseInt(match[1]);
                }
                if (count > 0) result.details.push({ type: 'Tajná správa', count: count });
            }
            if (itemText.indexOf('Reakci') > -1) {
                var rCount = 0;
                if (itemBadge) rCount = parseInt(itemBadge.textContent.trim()) || 0;
                else {
                    var rMatch = itemText.match(/(\\d+)/);
                    if (rMatch) rCount = parseInt(rMatch[1]);
                }
                if (rCount > 0) result.details.push({ type: 'Reakcia', count: rCount });
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
            }
        }
        
        // Start periodic checking every 30 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.checkForNotifications()
        }
        
        // Also check immediately after a short delay (let page load)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
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
            webView.evaluateJavaScript(self.monitorScript) { [weak self] result, error in
                guard let self = self,
                      let jsonString = result as? String,
                      let data = jsonString.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let totalCount = json["totalCount"] as? Int else {
                    return
                }
                
                let details = json["details"] as? [[String: Any]] ?? []
                
                // Update app badge
                UIApplication.shared.applicationIconBadgeNumber = totalCount
                
                // Check if count increased (new notification)
                if totalCount > self.lastBadgeCount && self.lastBadgeCount >= 0 {
                    let newCount = totalCount - self.lastBadgeCount
                    
                    if details.isEmpty {
                        // Generic notification
                        self.sendNotification(
                            title: "Birdz",
                            body: "Máš \(totalCount) neprečítaných notifikácií",
                            badge: totalCount
                        )
                    } else {
                        // Detailed notifications
                        for detail in details {
                            if let type = detail["type"] as? String,
                               let count = detail["count"] as? Int,
                               count > 0 {
                                let previousCount = self.lastNotificationDetails[type] ?? 0
                                if count > previousCount {
                                    self.sendNotification(
                                        title: "Birdz - \(type)",
                                        body: "Máš \(count) nových: \(type)",
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
        }
    }
    
    // Also try to get notification text preview by opening the menu temporarily
    func fetchNotificationPreview(webView: WKWebView, completion: @escaping (String?) -> Void) {
        let previewScript = """
        (function() {
            // Try to find and click the profile button to open menu
            var btn = document.querySelector('.button-more');
            if (btn) {
                btn.click();
                // Wait a moment, read the content, then close
                setTimeout(function() {
                    var menu = document.querySelector('.header_user_menu, .div-more');
                    var text = menu ? menu.innerText : '';
                    btn.click(); // close menu
                    window.webkit.messageHandlers.birdzPreview.postMessage(text);
                }, 500);
            }
            return null;
        })();
        """
        
        webView.evaluateJavaScript(previewScript) { result, error in
            completion(result as? String)
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
            }
        }
    }
}
