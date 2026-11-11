import Foundation

struct DeadlineCalendar {
    let calendar: Calendar
    let start: Date
    let end: Date
    let gridStart: Date
    let weekCount: Int

    init(now: Date = Date(), calendar: Calendar = .current) {
        var calendar = calendar
        calendar.firstWeekday = 1
        self.calendar = calendar
        start = calendar.dateInterval(of: .month, for: now)!.start
        end = calendar.date(byAdding: .year, value: 1, to: start)!
        gridStart = calendar.dateInterval(of: .weekOfYear, for: start)!.start
        let days = calendar.dateComponents([.day], from: gridStart, to: end).day!
        weekCount = (days + 6) / 7
    }
    func date(week: Int, weekday: Int) -> Date {
        calendar.date(byAdding: .day, value: week * 7 + weekday, to: gridStart)!
    }
    func contains(_ date: Date) -> Bool { date >= start && date < end }
    func deadlines(on date: Date, from deadlines: [Deadline]) -> [Deadline] {
        deadlines.filter { !$0.completed && calendar.isDate($0.date, inSameDayAs: date) }
    }
    var months: [Date] { (0..<12).map { calendar.date(byAdding: .month, value: $0, to: start)! } }
    func column(for date: Date) -> Int { calendar.dateComponents([.day], from: gridStart, to: date).day! / 7 }
}
