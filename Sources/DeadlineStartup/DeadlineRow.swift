import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DeadlineRow: View {
    let deadline: Deadline
    let open: () -> Void
    let edit: () -> Void
    let toggleCompleted: () -> Void
    let delete: () -> Void
    let reportError: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 2) {
                Text(deadline.date, format: .dateTime.month(.abbreviated)).font(.caption.bold()).textCase(.uppercase)
                Text(deadline.date, format: .dateTime.day()).font(.system(size: 27, weight: .semibold, design: .rounded))
                Text(deadline.date, format: .dateTime.year()).font(.caption2)
            }
            .environment(\.timeZone, deadline.hasTime == true ? deadline.timeZone : .current)
            .foregroundStyle(.teal).frame(width: 62).padding(.top, 4)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 28) {
                    details.frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)
                    timing.frame(width: 280, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 18) { details; timing }
            }.frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 14) {
                Button(action: edit) { Image(systemName: "pencil") }.help("Edit deadline")
                Menu {
                    Button(deadline.completed ? "Mark incomplete" : "Mark complete", action: toggleCompleted)
                    Button("Delete…", role: .destructive, action: delete)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
            }
        }
        .padding(20)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityAction(named: Text("Open deadline details"), open)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(deadline.name).font(.system(size: 23, weight: .semibold)).strikethrough(deadline.completed)
                if let url = deadline.url {
                    Link(destination: url) { Image(systemName: "globe").font(.title3) }
                        .help("Open event website").accessibilityLabel("Open website for \(deadline.name)")
                }
            }
            if let name = deadline.fullName, !name.isEmpty { Text(name).font(.system(size: 15)) }
            if let dates = deadline.eventDates, !dates.isEmpty { Text(dates).foregroundStyle(.secondary) }
            if let location = deadline.location, !location.isEmpty { Label(location, systemImage: "mappin.and.ellipse").foregroundStyle(.secondary) }
            if let notes = deadline.notes, !notes.isEmpty { Text("Note: \(notes)").font(.callout) }
            Text(deadline.kind).font(.caption.bold()).padding(.horizontal, 9).padding(.vertical, 4).background(.teal.opacity(0.1), in: Capsule())

        }.fixedSize(horizontal: false, vertical: true)
    }

    private var timing: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(deadline.countdown(now: context.date))
                    .font(.system(size: 21, weight: .medium, design: .rounded)).monospacedDigit()
            }
            Text("Deadline: \(deadline.deadlineDescription)").font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: exportCalendar) { Label("Add to calendar…", systemImage: "calendar.badge.plus") }
                .buttonStyle(.link).help("Save an iCalendar file for Apple Calendar, Google Calendar, Outlook, or Yahoo")
        }
    }

    private func exportCalendar() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ics") ?? .data]
        panel.nameFieldStringValue = "Deadline.ics"
        panel.title = "Save calendar reminder"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try deadline.calendarFile().write(to: url, atomically: true, encoding: .utf8) }
            catch { reportError("Could not save calendar reminder: \(error.localizedDescription)") }
        }
    }
}
