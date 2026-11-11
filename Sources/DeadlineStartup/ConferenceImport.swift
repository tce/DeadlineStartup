import Foundation

struct DeadlineCandidate: Identifiable, Sendable {
    var id = UUID()
    var date: Date
    var kind: String
    var hasTime: Bool
    var timeZone: String?
    var evidence: String
    var source: URL
}

struct ConferenceDraft: Sendable {
    var deadline: Deadline
    var candidates: [DeadlineCandidate]
    var sources: [URL]
    var warnings: [String]
}

struct ConferencePage: Sendable {
    var url: URL
    var title: String
    var lines: [String]
    var links: [URL]
    var eventName: String?
    var eventDates: String?
    var location: String?
    var topics: String?
}

enum ConferenceImportError: LocalizedError {
    case invalidURL, unavailable(String), unreadable
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Drop a complete http:// or https:// conference URL."
        case .unavailable(let message): return message
        case .unreadable: return "This page could not be read. Try dropping a direct HTML call-for-papers page."
        }
    }
}

actor ConferenceImporter {
    func analyze(_ input: String) async throws -> ConferenceDraft {
        guard let url = Self.webURL(input.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ConferenceImportError.invalidURL }
        guard !BrowserLink.isImage(url) else { throw ConferenceImportError.unavailable(BrowserLink.imageMessage) }
        let first = try await fetch(url)
        var pages = [first]
        var warnings: [String] = []
        // Follow only a few relevant links, never crawl an entire site.
        for link in first.links.prefix(3) {
            try Task.checkCancellation()
            do { pages.append(try await fetch(link)) }
            catch is CancellationError { throw CancellationError() }
            catch { warnings.append("Could not read \(link.absoluteString).") }
        }
        return Self.draft(from: pages, warnings: warnings)
    }

    private func fetch(_ url: URL) async throws -> ConferencePage {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("DeadlineStartup/1.3 (conference deadline importer)", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ConferenceImportError.unavailable("The conference website did not return a readable page. Try a direct call-for-papers URL.")
        }
        guard Self.webURL(response.url?.absoluteString ?? "") != nil else { throw ConferenceImportError.invalidURL }
        guard response.mimeType?.contains("html") == true || response.mimeType == "text/plain" else { throw ConferenceImportError.unreadable }
        var data = Data()
        for try await byte in bytes {
            if data.count >= 3_000_000 { throw ConferenceImportError.unavailable("The page is too large to import. Try its direct call-for-papers page.") }
            data.append(byte)
        }
        try Task.checkCancellation()
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        guard let html else { throw ConferenceImportError.unreadable }
        return try Self.parse(html: html, url: response.url ?? url)
    }

    static func webURL(_ value: String) -> URL? {
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func matches(_ pattern: String, _ text: String, caseSensitive: Bool = false) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(html: String, url: URL) throws -> ConferencePage {
        let document = try XMLDocument(xmlString: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        func nodes(_ path: String) -> [XMLNode] { (try? document.nodes(forXPath: path)) ?? [] }
        let title = clean(nodes("//title").first?.stringValue ?? nodes("//h1").first?.stringValue ?? url.host ?? "Conference")
        var page = ConferencePage(url: url, title: title, lines: [], links: [])
        // Schema.org Event metadata provides precise names, venues, and event dates when available.
        func readJSON(_ value: Any) {
            if let array = value as? [Any] { array.forEach(readJSON); return }
            guard let object = value as? [String: Any] else { return }
            let types = (object["@type"] as? [String]) ?? [object["@type"] as? String ?? ""]
            if types.contains(where: { $0.lowercased().contains("event") }) {
                page.eventName = object["name"] as? String
                if let start = object["startDate"] as? String {
                    page.eventDates = [start, object["endDate"] as? String].compactMap { $0 }.joined(separator: " – ")
                }
                if let place = object["location"] as? [String: Any] {
                    var parts = [place["name"] as? String].compactMap { $0 }
                    if let address = place["address"] as? [String: Any] {
                        parts += ["addressLocality", "addressRegion", "addressCountry"].compactMap { address[$0] as? String }
                    } else if let address = place["address"] as? String { parts.append(address) }
                    page.location = parts.joined(separator: ", ")
                } else { page.location = object["location"] as? String }
                page.topics = object["keywords"] as? String
            }
            if let graph = object["@graph"] { readJSON(graph) }
        }
        for script in nodes("//script[@type='application/ld+json']") {
            if let data = script.stringValue?.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) { readJSON(json) }
        }
        for anchor in nodes("//a[@href]") {
            guard let element = anchor as? XMLElement, let href = element.attribute(forName: "href")?.stringValue,
                  let link = URL(string: href, relativeTo: url)?.absoluteURL, webURL(link.absoluteString) != nil else { continue }
            let label = clean(anchor.stringValue ?? "") + " " + link.path
            if !matches("call.{0,12}(papers|submissions)|(^|[/ _-])cfp([/ ._-]|$)|important.{0,8}dates|submission.{0,8}(guidelines|dates)", label).isEmpty,
               link != url, !page.links.contains(link), link.pathExtension.lowercased() != "pdf" { page.links.append(link) }
        }
        for node in nodes("//script | //style | //nav | //header | //footer | //noscript") { node.detach() }
        let blocks: Set<String> = ["p", "div", "section", "article", "tr", "li", "h1", "h2", "h3", "h4", "br", "dt", "dd"]
        func text(_ node: XMLNode) -> String {
            if node.kind == .text { return node.stringValue ?? "" }
            let body = (node.children ?? []).map(text).joined(separator: (node.name == "tr" ? " | " : " "))
            return blocks.contains(node.name ?? "") ? "\n\(body)\n" : body
        }
        page.lines = text(nodes("//body").first ?? document).components(separatedBy: .newlines).map(clean).filter { !$0.isEmpty }
        if page.lines.isEmpty { throw ConferenceImportError.unreadable }
        func labeled(_ pattern: String) -> String? {
            guard let index = page.lines.firstIndex(where: { !matches(pattern, $0).isEmpty }) else { return nil }
            let value = clean(page.lines[index].replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive]))
            if !value.isEmpty { return value }
            return index + 1 < page.lines.count ? page.lines[index + 1] : nil
        }
        page.location = page.location ?? labeled("^(?:location|venue)\\b\\s*[:|]?\\s*")
        page.eventDates = page.eventDates ?? labeled("^(?:conference dates|event dates|dates)\\b\\s*[:|]?\\s*")
        page.topics = page.topics ?? labeled("^(?:topics|keywords|areas of interest)\\s*[:|]\\s*")
        if page.topics == nil {
            var inTopics = false
            var topics: [String] = []
            for heading in nodes("//h1 | //h2 | //h3") {
                let label = clean(heading.stringValue ?? "")
                if heading.name != "h3" {
                    inTopics = !matches("topic areas|topics of interest|areas of interest", label).isEmpty
                } else if inTopics, !label.isEmpty { topics.append(label) }
            }
            if !topics.isEmpty { page.topics = topics.joined(separator: ", ") }
        }
        if page.eventName == nil {
            page.eventName = nodes("//h1").compactMap { $0.stringValue }.map(clean).first(where: { !matches("conference|symposium|workshop", $0).isEmpty })
        }
        return page
    }

    static func candidates(in page: ConferencePage) -> [DeadlineCandidate] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        var results: [DeadlineCandidate] = []
        let units = page.lines.flatMap { line -> [String] in
            let separated = line.replacingOccurrences(of: "(?i)\\s+(?=Abstracts? due)", with: "\n", options: .regularExpression)
                .replacingOccurrences(of: "(?<=[.!?])\\s+(?=[A-Z])", with: "\n", options: .regularExpression)
            return separated.components(separatedBy: .newlines).map(clean).filter { !$0.isEmpty }
        }
        for (index, line) in units.enumerated() {
            guard !matches("deadline|\\bdue\\b|(?:abstract|paper)\\s+submission", line).isEmpty,
                  matches("notification|acceptance|camera.ready|rebuttal|withdraw|review period|to be announced|\\bTBA\\b|coming soon", line).isEmpty else { continue }
            // A deadline label may sit immediately before its date in a list or table.
            var evidence = line
            if matches("\\b20\\d{2}\\b", evidence).isEmpty, index + 1 < units.count, line.count < 120 { evidence += " " + units[index + 1] }
            guard !matches("\\b20\\d{2}\\b", evidence).isEmpty else { continue }
            // Detect the calendar date independently from the clock and UTC offset.
            // Otherwise a late AoE deadline can shift to the next local day twice.
            let dateEvidence = evidence
                .replacingOccurrences(of: "\\b\\d{1,2}:\\d{2}(?::\\d{2})?(?:\\s*[ap]m)?|\\b\\d{1,2}\\s*[ap]m\\b", with: "", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: "(?:UTC|GMT)\\s*[+−-]?\\s*\\d{0,2}(?::\\d{2})?|\\bAoE\\b", with: "", options: [.regularExpression, .caseInsensitive])
            let found = detector.matches(in: dateEvidence, range: NSRange(dateEvidence.startIndex..., in: dateEvidence))
            let kind = !matches("abstract", line).isEmpty ? "Abstract" : !matches("\\breview\\b.{0,15}(deadline|due)|\\breviews? due", line).isEmpty ? "Review" : !matches("letter", line).isEmpty ? "Letter" : "Paper"
            for match in found {
                guard let detected = match.date, let range = Range(match.range, in: dateEvidence) else { continue }
                let dateText = String(dateEvidence[range])
                guard !matches("20\\d{2}", dateText).isEmpty else { continue }
                let timeText = matches("\\b\\d{1,2}:\\d{2}(?::\\d{2})?(?:\\s*[ap]m)?|\\b\\d{1,2}\\s*[ap]m\\b", evidence).first
                var zone: TimeZone?
                if !matches("\\bAoE\\b|anywhere on earth|UTC\\s*[−-]\\s*12", evidence).isEmpty { zone = TimeZone(identifier: "Etc/GMT+12") }
                else if !matches("\\bUTC\\b|\\bGMT\\b", evidence).isEmpty {
                    if let offset = matches("(?:UTC|GMT)\\s*[+−-]\\s*\\d{1,2}(?::\\d{2})?", evidence).first {
                        let numbers = matches("\\d+", offset).compactMap(Int.init)
                        let sign = offset.contains("+") ? 1 : -1
                        zone = TimeZone(secondsFromGMT: sign * ((numbers.first ?? 0) * 3600 + (numbers.count > 1 ? numbers[1] * 60 : 0)))
                    } else { zone = TimeZone(secondsFromGMT: 0) }
                }
                // Keep an unqualified clock time for review; never invent its time zone.
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = .current
                var components = calendar.dateComponents([.year, .month, .day], from: detected)
                let precise = timeText != nil && zone != nil
                if let timeText, precise {
                    let numbers = matches("\\d+", timeText).compactMap(Int.init)
                    var hour = numbers.first ?? 0
                    if timeText.lowercased().contains("pm") && hour < 12 { hour += 12 }
                    if timeText.lowercased().contains("am") && hour == 12 { hour = 0 }
                    components.hour = hour; components.minute = numbers.count > 1 ? numbers[1] : 0; components.second = numbers.count > 2 ? numbers[2] : 0
                    calendar.timeZone = zone!
                }
                components.timeZone = calendar.timeZone
                guard let date = calendar.date(from: components) else { continue }
                if !results.contains(where: { $0.date == date && $0.kind == kind }) {
                    results.append(DeadlineCandidate(date: date, kind: kind, hasTime: precise, timeZone: precise ? zone?.identifier : nil, evidence: evidence, source: page.url))
                }
            }
        }
        return results
    }

    static func draft(from pages: [ConferencePage], warnings: [String] = []) -> ConferenceDraft {
        let first = pages[0]
        var candidates: [DeadlineCandidate] = []
        for page in pages {
            for item in Self.candidates(in: page) {
                if !candidates.contains(where: { $0.date == item.date && $0.kind == item.kind }) { candidates.append(item) }
            }
        }
        candidates.sort { $0.date < $1.date }
        let title = pages.compactMap(\.eventName).first ?? first.title
        let acronym = matches("\\b[A-Z][A-Z0-9-]{1,12}\\s+20\\d{2}\\b", first.title, caseSensitive: true).first
        var deadline = Deadline(date: Date(), name: acronym ?? title, kind: "Paper", link: first.url.absoluteString)
        deadline.fullName = title
        deadline.eventDates = pages.compactMap(\.eventDates).first
        deadline.location = pages.compactMap(\.location).first
        deadline.topics = pages.compactMap(\.topics).first
        var notes = warnings
        if candidates.isEmpty { notes.append("No unambiguous deadline with an explicit year was found. Set the due date manually.") }
        if candidates.count > 1 { notes.append("Several deadlines were found. Select all the deadlines you want to track.") }
        if deadline.eventDates == nil { notes.append("Event dates were not identified; fill them in if needed.") }
        if deadline.location == nil { notes.append("Location was not identified; fill it in if needed.") }
        return ConferenceDraft(deadline: deadline, candidates: candidates, sources: pages.map(\.url), warnings: notes)
    }
}
