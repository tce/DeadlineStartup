import SwiftUI

struct DeadlineYearGrid: View {
    let deadlines: [Deadline]
    let savedSessions: [WritingSession]
    @ObservedObject private var tracker = WritingTracker.shared
    var body: some View {
        TimelineView(.periodic(from: .now, by: 3600)) { timeline in
            let model = DeadlineCalendar(now: timeline.date)
            let sessions = WritingSession.merging(savedSessions, tracker.sessions(in: SavedData()))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Deadline year").font(.caption.weight(.medium))
                    Spacer()
                    Text("\(model.start.formatted(.dateTime.month(.abbreviated).year())) – \(model.calendar.date(byAdding: .day, value: -1, to: model.end)!.formatted(.dateTime.month(.abbreviated).year()))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                GeometryReader { geometry in
                    let labelWidth: CGFloat = 30
                    let gap: CGFloat = 3
                    let size: CGFloat = 9
                    let step = size + gap
                    let rowStep = size + gap
                    ZStack(alignment: .topLeading) {
                        Canvas { context, _ in
                            for month in model.months {
                                let x = labelWidth + CGFloat(model.column(for: month)) * step
                                context.draw(Text(month.formatted(.dateTime.month(.abbreviated))).font(.system(size: 11)), at: CGPoint(x: x, y: 0), anchor: .topLeading)
                            }
                            for (row, label) in [(1, "Mon"), (3, "Wed"), (5, "Fri")] {
                                context.draw(Text(label).font(.system(size: 10)).foregroundColor(.secondary), at: CGPoint(x: 0, y: 23 + CGFloat(row) * rowStep + size / 2), anchor: .leading)
                            }
                        }.accessibilityHidden(true)
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(0..<model.weekCount, id: \.self) { week in
                                VStack(spacing: gap) {
                                    ForEach(0..<7, id: \.self) { row in
                                        let date = model.date(week: week, weekday: row)
                                        let items = model.deadlines(on: date, from: deadlines)
                                        let inRange = model.contains(date)
                                        CalendarDayCell(marked: inRange && !items.isEmpty, worked: inRange && WritingSession.greenDay(date, sessions: sessions), today: model.calendar.isDate(date, inSameDayAs: timeline.date))
                                            .frame(width: size, height: size)
                                            .opacity(inRange ? 1 : 0)
                                            .help(description(date, items: items, worked: WritingSession.greenDay(date, sessions: sessions)))
                                            .accessibilityLabel(description(date, items: items, worked: WritingSession.greenDay(date, sessions: sessions)))
                                            .accessibilityHidden(!inRange)
                                    }
                                }.frame(width: step, alignment: .leading)
                            }
                        }.padding(.leading, labelWidth).padding(.top, 23)
                    }
                }.frame(width: 30 + CGFloat(model.weekCount) * 12 - 3, height: 104)
            }.fixedSize(horizontal: true, vertical: false)
        }
    }
    private func description(_ date: Date, items: [Deadline], worked: Bool) -> String {
        let date = date.formatted(date: .complete, time: .omitted)
        let activity = worked ? "\nOverleaf session longer than one minute" : ""
        return (items.isEmpty ? "\(date): no deadlines" : date + "\n" + items.map { "\($0.name) — \($0.kind)" }.joined(separator: "\n")) + activity
    }
}

private struct CalendarDayCell: View {
    let marked: Bool
    let worked: Bool
    let today: Bool
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let shape = Path(rect.insetBy(dx: 0.25, dy: 0.25))
            context.clip(to: shape)
            context.fill(Path(rect), with: .color(worked ? .green : marked ? .white : Color(nsColor: .quaternaryLabelColor).opacity(0.25)))
            if marked && !worked {
                let side = size.width / 4
                for row in 0..<4 {
                    for column in 0..<4 where (row + column).isMultiple(of: 2) {
                        context.fill(Path(CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side)), with: .color(.black))
                    }
                }
            }
            context.stroke(shape, with: .color(today ? .accentColor : .gray.opacity(0.25)), lineWidth: today ? 2 : 0.5)
        }
    }
}
