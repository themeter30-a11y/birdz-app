import UIKit
import Capacitor

extension AppDelegate {
    
    func setupBirdzMonitoring() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.startBirdzMonitoringIfPossible()
        }

        startBirdzMonitoringIfPossible(after: 1.0)
    }

    private func startBirdzMonitoringIfPossible(after delay: TimeInterval = 0.0, retries: Int = 8) {
        let start = { [weak self] in
            guard let self = self else { return }

            guard let rootVC = self.window?.rootViewController as? CAPBridgeViewController,
                  let webView = rootVC.webView else {
                if retries > 0 {
                    self.startBirdzMonitoringIfPossible(after: 1.0, retries: retries - 1)
                }
                return
            }

            BirdzNotificationMonitor.shared.startMonitoring(webView: webView)
            print("BirdzMonitor: Started – hard refresh every 5s")
        }

        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: start)
        } else {
            DispatchQueue.main.async(execute: start)
        }
    }
}
