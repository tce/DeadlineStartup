import Foundation

struct Deadline: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var date: Date
    var name: String
    var kind: String
    var link: String
    var completed = false
    // Optional fields keep files from earlier versions readable.
    var fullName: String?
    var eventDates: String?
    var location: String?
    var notes: String?
    var topics: String?
    var hasTime: Bool?
    var timeZoneIdentifier: String?
    var about: String?
    var actions: [DeadlineAction]?
    var overleafProjectURL: String?
    var localProjectPath: String?
    /// Bundle identifier of the application that opens the local project; nil means Emacs.
    var localProjectApp: String?

    var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier ?? "") ?? .current }
    var topicList: [String] {
        (topics ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    func countdown(now: Date) -> String {
        if completed { return "Completed" }
        if hasTime == true {
            let seconds = Int(date.timeIntervalSince(now).rounded(.up))
            guard seconds > 0 else { return "Deadline passed" }
            return String(format: "%02d days %02dh %02dm %02ds", seconds / 86400, seconds / 3600 % 24, seconds / 60 % 60, seconds % 60)
        }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now), to: Calendar.current.startOfDay(for: date)).day ?? 0
        if days < 0 { return "Deadline passed" }
        return days == 0 ? "Due today" : days == 1 ? "Due tomorrow" : "\(days) days remaining"
    }
    var deadlineDescription: String {
        let formatter = DateFormatter()
        if hasTime == true {
            formatter.timeZone = timeZone
            formatter.dateFormat = "EEE MMM d yyyy HH:mm:ss 'GMT'Z"
        } else { formatter.dateStyle = .full }
        return formatter.string(from: date)
    }
    func calendarFile(now: Date = Date()) -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Deadline Startup//EN", "BEGIN:VEVENT", "UID:\(id.uuidString)@deadlinestartup", "DTSTAMP:\(formatter.string(from: now))"]
        if hasTime == true { lines.append("DTSTART:\(formatter.string(from: date))") }
        else {
            formatter.timeZone = .current
            formatter.dateFormat = "yyyyMMdd"
            lines.append("DTSTART;VALUE=DATE:\(formatter.string(from: date))")
            let end = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
            lines.append("DTEND;VALUE=DATE:\(formatter.string(from: end))")
        }
        lines.append("SUMMARY:\(escape(name + " — " + kind))")
        lines.append("DESCRIPTION:\(escape([fullName, eventDates, notes].compactMap { $0 }.joined(separator: "\n")))")
        if let location, !location.isEmpty { lines.append("LOCATION:\(escape(location))") }
        if let url { lines.append("URL:\(escape(url.absoluteString))") }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        // RFC 5545 folds lines at 75 UTF-8 bytes without splitting a character.
        return lines.map { line in
            var folded = "", count = 0
            for character in line {
                let size = String(character).utf8.count
                if count + size > 75 { folded += "\r\n "; count = 1 }
                folded.append(character); count += size
            }
            return folded
        }.joined(separator: "\r\n") + "\r\n"
    }

    var url: URL? {
        guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
    func isSameConference(as other: Deadline) -> Bool {
        func normalized(_ value: String) -> String {
            value.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let title = normalized(name)
        if !title.isEmpty && title == normalized(other.name) { return true }
        func year(_ name: String) -> String? {
            guard let range = name.range(of: "\\b20[0-9]{2}\\b", options: .regularExpression) else { return nil }
            return String(name[range])
        }
        // A shared website alone must not merge different conference editions.
        guard let edition = year(name), edition == year(other.name), let url, let otherURL = other.url else { return false }
        func host(_ url: URL) -> String { (url.host ?? "").lowercased().replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression) }
        return host(url) == host(otherURL) && url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == otherURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func upcoming(_ deadlines: [Deadline], now: Date = Date()) -> [Deadline] {
        let today = Calendar.current.startOfDay(for: now)
        return deadlines.filter { !$0.completed && $0.date >= today }.sorted { $0.date == $1.date ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.date < $1.date }
    }
}

struct SavedData: Codable, Sendable {
    var deadlines: [Deadline] = []
    var kinds = ["Abstract", "Paper", "Review", "Letter"]
    var writingSessions: [WritingSession]?

    func upserting(_ imported: [Deadline]) -> SavedData {
        var updated = self
        for deadline in imported {
            if let index = updated.deadlines.firstIndex(where: { $0.id == deadline.id }) { updated.deadlines[index] = deadline }
            else { updated.deadlines.append(deadline) }
            if !updated.kinds.contains(where: { $0.caseInsensitiveCompare(deadline.kind) == .orderedSame }) { updated.kinds.append(deadline.kind) }
        }
        return updated.sharingExistingDetails()
    }

    func linkingOverleaf(_ url: String, for source: Deadline) -> SavedData {
        var updated = self
        for index in updated.deadlines.indices where updated.deadlines[index].isSameConference(as: source) {
            updated.deadlines[index].overleafProjectURL = url
        }
        return updated
    }

    func linkingLocalProject(_ path: String, app: String? = nil, for source: Deadline) -> SavedData {
        var updated = self
        for index in updated.deadlines.indices where updated.deadlines[index].isSameConference(as: source) {
            updated.deadlines[index].localProjectPath = path
            updated.deadlines[index].localProjectApp = app
        }
        return updated
    }

    func sharingDetails(from source: Deadline) -> SavedData {
        var updated = self
        for index in updated.deadlines.indices where updated.deadlines[index].isSameConference(as: source) {
            updated.deadlines[index].about = source.about
            updated.deadlines[index].actions = source.actions
        }
        return updated
    }

    /// Backfill older data without discarding distinct descriptions or task IDs.
    func sharingExistingDetails() -> SavedData {
        var updated = self
        var visited: Set<UUID> = []
        for deadline in deadlines where !visited.contains(deadline.id) {
            let group = deadlines.filter { $0.isSameConference(as: deadline) }
            visited.formUnion(group.map(\.id))
            var descriptions: [String] = []
            var tasks: [DeadlineAction] = []
            for item in group {
                if let text = item.about, !text.isEmpty, !descriptions.contains(text) { descriptions.append(text) }
                for action in item.actions ?? [] {
                    if let index = tasks.firstIndex(where: { $0.id == action.id }) { tasks[index].completed = tasks[index].completed || action.completed }
                    else { tasks.append(action) }
                }
            }
            if let project = group.compactMap(\.overleafProjectURL).first {
                for index in updated.deadlines.indices where updated.deadlines[index].isSameConference(as: deadline) && updated.deadlines[index].overleafProjectURL == nil {
                    updated.deadlines[index].overleafProjectURL = project
                }
            }
            if let linked = group.first(where: { $0.localProjectPath != nil }) {
                for index in updated.deadlines.indices where updated.deadlines[index].isSameConference(as: deadline) && updated.deadlines[index].localProjectPath == nil {
                    updated.deadlines[index].localProjectPath = linked.localProjectPath
                    updated.deadlines[index].localProjectApp = linked.localProjectApp
                }
            }
            guard !descriptions.isEmpty || !tasks.isEmpty else { continue }
            var shared = deadline
            shared.about = descriptions.isEmpty ? nil : descriptions.joined(separator: "\n\n")
            shared.actions = tasks.isEmpty ? nil : tasks
            updated = updated.sharingDetails(from: shared)
        }
        return updated
    }
}


struct DeadlineAction: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var completed = false
}
