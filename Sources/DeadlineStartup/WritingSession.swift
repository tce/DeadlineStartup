import Foundation

struct WritingSession: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var deadlineID: UUID
    var conferenceName: String
    var conferenceLink: String
    var projectURL: String?
    /// Name of the application used (Overleaf, Emacs, TeXShop, …). Older sessions omit it.
    var application: String?
    var startedAt: Date
    var openedDay: String
    var seconds: TimeInterval = 0

    init(deadline: Deadline, now: Date = Date(), calendar: Calendar = .current) {
        deadlineID = deadline.id; conferenceName = deadline.name; conferenceLink = deadline.link
        projectURL = deadline.overleafProjectURL; startedAt = now
        openedDay = Self.dayKey(now, calendar: calendar)
    }
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    func belongs(to deadline: Deadline) -> Bool {
        if let projectURL, projectURL == deadline.overleafProjectURL || projectURL == deadline.localProjectPath.map({ URL(fileURLWithPath: $0).absoluteString }) { return true }
        if deadlineID == deadline.id { return true }
        return deadline.isSameConference(as: Deadline(date: startedAt, name: conferenceName, kind: "", link: conferenceLink))
    }
    /// Older sessions predate `application`; local ones were always Emacs.
    var applicationName: String {
        application ?? (projectURL?.hasPrefix("file:") == true ? "Emacs" : "Overleaf")
    }
    /// Opening count and total time per application, most-used first.
    static func usageByApplication(_ sessions: [WritingSession]) -> [(name: String, count: Int, seconds: TimeInterval)] {
        Dictionary(grouping: sessions, by: \.applicationName)
            .map { (name: $0.key, count: $0.value.count, seconds: $0.value.reduce(0) { $0 + $1.seconds }) }
            .sorted { $0.seconds == $1.seconds ? $0.name < $1.name : $0.seconds > $1.seconds }
    }
    func checkpoint(at now: Date) -> WritingSession {
        var copy = self; copy.seconds = max(seconds, now.timeIntervalSince(startedAt), 0); return copy
    }
    static func merging(_ saved: [WritingSession], _ live: [WritingSession]) -> [WritingSession] {
        var sessions = saved
        for session in live {
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                if session.seconds >= sessions[index].seconds { sessions[index] = session }
            } else { sessions.append(session) }
        }
        return sessions
    }
    static func greenDay(_ date: Date, sessions: [WritingSession], calendar: Calendar = .current) -> Bool {
        let key = dayKey(date, calendar: calendar)
        return sessions.contains { $0.openedDay == key && $0.seconds > 60 }
    }
    /// Compact hh:mm form for narrow spaces, e.g. "00:45", "02:05", "112:30".
    static func shortDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds)) / 60
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
    static func duration(_ seconds: TimeInterval) -> String {
        let seconds = Int(max(0, seconds))
        return String(format: "%dh %02dm %02ds", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}
