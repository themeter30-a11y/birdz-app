import UIKit
import Capacitor

// This extension hooks into the Capacitor app lifecycle
// to start monitoring birdz.sk notifications
extension AppDelegate {
    
    // Call this from application(_:didFinishLaunchingWithOptions:)
    func setupBirdzMonitoring() {
        // Wait for the WebView to be ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if let rootVC = self.window?.rootViewController as? CAPBridgeViewController,
               let webView = rootVC.webView {
                BirdzNotificationMonitor.shared.startMonitoring(webView: webView)
                print("BirdzMonitor: Started monitoring birdz.sk notifications")
            }
        }
    }
}
