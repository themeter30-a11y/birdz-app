import UIKit
import Capacitor

extension AppDelegate {
    
    func setupBirdzMonitoring() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if let rootVC = self.window?.rootViewController as? CAPBridgeViewController,
               let webView = rootVC.webView {
                BirdzNotificationMonitor.shared.startMonitoring(webView: webView)
                print("BirdzMonitor: Started – polling every 5s")
            }
        }
    }
}
