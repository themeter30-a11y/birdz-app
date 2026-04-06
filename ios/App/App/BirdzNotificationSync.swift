import Foundation

struct BirdzScrapedNotificationItem {
    let type: String
    let author: String
    let text: String
    let target: String
    let time: String
    let link: String

    init(dictionary: [String: Any]) {
        type = Self.trim(dictionary["type"] as? String)
        author = Self.trim(dictionary["author"] as? String)
        text = Self.trim(dictionary["text"] as? String)
        target = Self.trim(dictionary["target"] as? String)
        time = Self.trim(dictionary["time"] as? String)
        link = Self.trim(dictionary["link"] as? String)
    }

    var isMeaningful: Bool {
        !type.isEmpty || !author.isEmpty || !text.isEmpty || !target.isEmpty
    }

    var fingerprint: String {
        BirdzStableHasher.hash([
            Self.normalize(type),
            Self.normalize(author),
            Self.normalize(text),
            Self.normalize(target),
            Self.normalize(time)
        ].joined(separator: "|"))
    }

    private static func trim(_ value: String?) -> String {
        (value ?? "")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalize(_ value: String) -> String {
        trim(value).lowercased()
    }
}

enum BirdzNotificationSyncStore {
    private static let deliveredCountsKey = "birdz_delivered_notification_counts"

    static func unsentItems(from parsedItems: [BirdzScrapedNotificationItem], unreadCount: Int) -> [BirdzScrapedNotificationItem] {
        let safeUnreadCount = max(unreadCount, 0)
        guard safeUnreadCount > 0 else {
            storeDeliveredCounts([:])
            return []
        }

        let visibleUnreadItems = Array(parsedItems.prefix(safeUnreadCount))
        guard !visibleUnreadItems.isEmpty else {
            return []
        }

        let visibleCounts = makeCounts(from: visibleUnreadItems)
        let deliveredCounts = prunedDeliveredCounts(for: visibleCounts)
        storeDeliveredCounts(deliveredCounts)
        var currentCounts: [String: Int] = [:]
        var missingItems: [BirdzScrapedNotificationItem] = []

        for item in visibleUnreadItems {
            let fingerprint = item.fingerprint
            currentCounts[fingerprint, default: 0] += 1

            if currentCounts[fingerprint, default: 0] > deliveredCounts[fingerprint, default: 0] {
                missingItems.append(item)
            }
        }

        return missingItems
    }

    static func markDelivered(_ item: BirdzScrapedNotificationItem) {
        var counts = loadDeliveredCounts()
        counts[item.fingerprint, default: 0] += 1
        storeDeliveredCounts(counts)
    }

    private static func loadDeliveredCounts() -> [String: Int] {
        guard let raw = UserDefaults.standard.dictionary(forKey: deliveredCountsKey) else {
            return [:]
        }

        var counts: [String: Int] = [:]
        for (key, value) in raw {
            if let intValue = value as? Int {
                counts[key] = intValue
            } else if let numberValue = value as? NSNumber {
                counts[key] = numberValue.intValue
            }
        }

        return counts
    }

    private static func makeCounts(from items: [BirdzScrapedNotificationItem]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for item in items {
            counts[item.fingerprint, default: 0] += 1
        }
        return counts
    }

    private static func prunedDeliveredCounts(for visibleCounts: [String: Int]) -> [String: Int] {
        let deliveredCounts = loadDeliveredCounts()
        var pruned: [String: Int] = [:]

        for (fingerprint, visibleCount) in visibleCounts {
            let capped = min(deliveredCounts[fingerprint, default: 0], visibleCount)
            if capped > 0 {
                pruned[fingerprint] = capped
            }
        }

        return pruned
    }

    private static func storeDeliveredCounts(_ counts: [String: Int]) {
        UserDefaults.standard.set(counts, forKey: deliveredCountsKey)
    }
}

private enum BirdzStableHasher {
    static func hash(_ text: String) -> String {
        var hash = 0
        for scalar in text.unicodeScalars {
            hash = ((hash &<< 5) &- hash) &+ Int(scalar.value)
        }
        return String(hash, radix: 36)
    }
}