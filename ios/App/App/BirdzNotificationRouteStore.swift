import Foundation

extension Notification.Name {
    static let birdzPendingDeepLinkDidChange = Notification.Name("birdzPendingDeepLinkDidChange")
}

enum BirdzNotificationRouteStore {
    private static let pendingDeepLinkKey = "birdz_pending_deep_link"

    static func store(_ urlString: String) {
        guard let normalized = normalize(urlString) else { return }
        UserDefaults.standard.set(normalized, forKey: pendingDeepLinkKey)
        NotificationCenter.default.post(name: .birdzPendingDeepLinkDidChange, object: nil)
    }

    static func peek() -> String? {
        guard let raw = UserDefaults.standard.string(forKey: pendingDeepLinkKey) else { return nil }
        return normalize(raw)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: pendingDeepLinkKey)
    }

    static func normalize(_ urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("//") {
            return normalize("https:\(trimmed)")
        }

        if trimmed.hasPrefix("/") {
            return URL(string: trimmed, relativeTo: URL(string: "https://www.birdz.sk"))?.absoluteURL.absoluteString
        }

        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(),
              host.contains("birdz.sk") else {
            return nil
        }

        return url.absoluteString
    }
}
