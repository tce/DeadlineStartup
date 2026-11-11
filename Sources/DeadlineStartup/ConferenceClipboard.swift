import AppKit

@MainActor
enum ConferenceClipboard {
    // Read only in response to the user's paste command, never on activation.
    static func url(from pasteboard: NSPasteboard) -> URL? {
        var values: [(text: String, html: Bool)] = []
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType("com.apple.webarchive")),
           let html = BrowserLink.archiveHTML(data) { values.append((html, true)) }
        if let html = pasteboard.string(forType: .html) { values.append((html, true)) }
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType")),
           let urls = BrowserLink.browserURLList(data) { values.append((urls, false)) }
        for type in [NSPasteboard.PasteboardType.URL, .string] {
            if let string = pasteboard.string(forType: type) { values.append((string, false)) }
        }
        return BrowserLink.preferred(values)
    }
}
