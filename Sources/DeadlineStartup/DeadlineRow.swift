import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DeadlineRow: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var tracker = WritingTracker.shared
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
                usage.padding(.top, 8)
            }
            .environment(\.timeZone, deadline.hasTime == true ? deadline.timeZone : .current)
            .foregroundStyle(.teal)
            .frame(width: 62).padding(.top, 4)

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
            HStack(spacing: 6) {
                Text(deadline.kind).font(.caption.bold()).padding(.horizontal, 9).padding(.vertical, 4).background(.teal.opacity(0.1), in: Capsule())
                if let path = deadline.localProjectPath {
                    let app = ProjectEditor.name(for: deadline.localProjectApp)
                    projectTag(app, systemImage: "folder", help: "Open \(URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent) in \(app)") {
                        LocalProjects.shared.open(deadline: deadline, store: store) { store.error = $0 }
                    }
                }
                if deadline.overleafProjectURL != nil {
                    projectTag("Overleaf", systemImage: "leaf", help: "Open the linked Overleaf project") {
                        OverleafWindows.shared.open(deadline: deadline, store: store)
                    }
                }
            }

        }.fixedSize(horizontal: false, vertical: true)
    }

    /// Openings and time across Overleaf and local projects, shown under the date.
    private var usage: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let sessions = tracker.sessions(in: store.data).filter { $0.belongs(to: deadline) }
            VStack(spacing: 1) {
                Label("\(sessions.count)×", systemImage: "arrow.up.right.square")
                Label(WritingSession.shortDuration(sessions.reduce(0) { $0 + $1.seconds }), systemImage: "clock")
            }
            .labelStyle(.titleAndIcon).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            .lineLimit(1).fixedSize()
            .help("Opened \(sessions.count) times · \(WritingSession.duration(sessions.reduce(0) { $0 + $1.seconds })) worked")
            .accessibilityElement(children: .combine)
        }
    }

    private func projectTag(_ title: String, systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).font(.caption.bold())
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).help(help)
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
