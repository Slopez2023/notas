import Foundation

/// Links a note may open or print: web pages and mail only. A bare "example.com" becomes https.
enum OpenableLink {
    static func url(from link: Any?) -> URL? {
        let raw = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
        let text = raw.contains("://") || raw.lowercased().hasPrefix("mailto:") ? raw : "https://\(raw)"
        guard !raw.isEmpty, let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else {
            return nil
        }
        return url
    }
}
