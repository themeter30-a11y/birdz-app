import Foundation

enum BirdzHTMLLinkMatcher {
    static func bestDeepLink(in html: String, matchingText text: String) -> String? {
        let snippetTokens = tokenSet(from: text)
        guard !snippetTokens.isEmpty,
              let regex = try? NSRegularExpression(
                pattern: #"<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#,
                options: [.caseInsensitive]
              ) else {
            return nil
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var bestLink: String?
        var bestScore = 0

        regex.enumerateMatches(in: html, options: [], range: range) { match, _, _ in
            guard let match,
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let innerHTMLRange = Range(match.range(at: 2), in: html) else {
                return
            }

            guard let href = BirdzNotificationRouteStore.normalize(String(html[hrefRange])) else { return }

            let anchorText = normalizedText(fromHTMLFragment: String(html[innerHTMLRange]))
            let score = similarityScore(
                between: snippetTokens,
                and: tokenSet(from: anchorText),
                anchorText: anchorText,
                snippetText: text
            )

            guard score > bestScore else { return }
            bestScore = score
            bestLink = href
        }

        return bestScore > 0 ? bestLink : nil
    }

    private static func similarityScore(
        between snippetTokens: Set<String>,
        and anchorTokens: Set<String>,
        anchorText: String,
        snippetText: String
    ) -> Int {
        let overlap = snippetTokens.intersection(anchorTokens).count
        guard overlap > 0 else { return 0 }

        var score = overlap * 100
        let normalizedAnchor = anchorText.lowercased()
        let normalizedSnippet = normalizedText(fromHTMLFragment: snippetText).lowercased()

        if normalizedAnchor.count > 8 && normalizedSnippet.contains(normalizedAnchor) {
            score += 40
        }

        if normalizedSnippet.count > 8 && normalizedAnchor.contains(normalizedSnippet) {
            score += 40
        }

        if normalizedAnchor.contains("koment") ||
            normalizedAnchor.contains("označil") ||
            normalizedAnchor.contains("oznacil") ||
            normalizedAnchor.contains("reagoval") {
            score += 20
        }

        score += min(anchorText.count, 160) / 8
        return score
    }

    private static func tokenSet(from text: String) -> Set<String> {
        let normalized = normalizedText(fromHTMLFragment: text).lowercased()
        let parts = normalized.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(parts.filter { $0.count > 2 })
    }

    private static func normalizedText(fromHTMLFragment html: String) -> String {
        html
            .replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
