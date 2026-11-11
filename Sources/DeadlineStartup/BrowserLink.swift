import Foundation

/// Browser drags may supply an HTML anchor, a Markdown link, a URL, or just an image URL.
enum BrowserLink {
    static func isImage(_ url: URL) -> Bool {
        ["svg", "png", "jpg", "jpeg", "gif", "webp", "ico", "avif"].contains(url.pathExtension.lowercased())
    }

    static func extract(_ value: String, html: Bool = false) -> [URL] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = ConferenceImporter.webURL(trimmed), !trimmed.contains(where: { $0.isWhitespace }) { return [url] }
        var strings: [String] = []
        if html {
            // Read anchor destinations, never the nested image's src or embedded scripts.
            if let document = try? XMLDocument(xmlString: value, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
               let anchors = try? document.nodes(forXPath: "//a[@href]") {
                strings = anchors.compactMap { ($0 as? XMLElement)?.attribute(forName: "href")?.stringValue }
                let base = (try? document.nodes(forXPath: "//base[@href]"))?.first as? XMLElement
                if let baseURL = base?.attribute(forName: "href")?.stringValue.flatMap(ConferenceImporter.webURL) {
                    strings = strings.compactMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL.absoluteString }
                }
            }
        } else {
            let pattern = #"\[[^\]]*\]\(\s*(https?://[^\s)]+)\s*\)|<(https?://[^\s>]+)>"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
                    for index in 1..<match.numberOfRanges {
                        if let range = Range(match.range(at: index), in: value) { strings.append(String(value[range])) }
                    }
                }
            }
            // URL/title and text/uri-list representations use one URL per line.
            strings += value.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return strings.compactMap(ConferenceImporter.webURL)
    }

    static func preferred(_ representations: [(text: String, html: Bool)]) -> URL? {
        let urls = representations.flatMap { extract($0.text, html: $0.html) }
        return urls.first(where: { !isImage($0) }) ?? urls.first
    }

    static func archiveHTML(_ data: Data) -> String? {
        guard let archive = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let main = archive["WebMainResource"] as? [String: Any],
              let bytes = main["WebResourceData"] as? Data else { return nil }
        return String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .utf16)
    }

    static func browserURLList(_ data: Data) -> String? {
        guard let lists = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String]],
              let urls = lists.first else { return nil }
        return urls.joined(separator: "\n")
    }

    static let imageMessage = "This link contains only the globe icon’s image URL, which does not identify a conference. Drag the conference title or its linked website address instead."
}
