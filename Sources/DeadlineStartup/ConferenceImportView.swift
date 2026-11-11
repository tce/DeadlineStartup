import SwiftUI
import UniformTypeIdentifiers

struct ConferenceImportView: View {
    @Environment(\.dismiss) private var dismiss
    let input: String
    let onReview: ([Deadline], Bool) -> Void
    @State private var draft: ConferenceDraft?
    @State private var selection: Set<UUID> = []
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import conference").font(.title2.bold())
            if let draft {
                Text(draft.deadline.name).font(.headline)
                Text("Review the source and select the deadlines to track. Review each before saving.").foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if draft.candidates.count > 1 {
                            HStack {
                                Text("\(selection.count) selected").font(.subheadline)
                                Spacer()
                                Button("Select all") { selection = Set(draft.candidates.map(\.id)) }
                                Button("Clear") { selection.removeAll() }
                            }
                        }
                        ForEach(draft.candidates) { candidate in
                            Toggle(isOn: Binding(get: { selection.contains(candidate.id) }, set: { selected in
                                if selected { selection.insert(candidate.id) } else { selection.remove(candidate.id) }
                            })) {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("\(candidate.kind) · \(candidate.date.formatted(date: .abbreviated, time: .omitted))").font(.headline)
                                        Text(candidate.evidence).font(.callout).textSelection(.enabled)
                                        Text(candidate.source.absoluteString).font(.caption).foregroundStyle(.secondary)
                                        if !candidate.hasTime { Text("Date only — verify the cutoff time and time zone.").font(.caption).foregroundStyle(.orange) }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            }.toggleStyle(.checkbox).padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                        ForEach(draft.warnings, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                        Text("Sources").font(.headline)
                        ForEach(draft.sources, id: \.self) { url in Link(url.absoluteString, destination: url).font(.caption) }
                    }
                }
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(draft.candidates.isEmpty ? "Enter deadline manually" : "Review \(selection.count) selected") { review(draft) }
                        .buttonStyle(.borderedProminent).disabled(!draft.candidates.isEmpty && selection.isEmpty)
                }
            } else if let error {
                Text(error).foregroundStyle(.secondary)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            } else {
                ProgressView("Reading conference page and linked calls for papers…")
                Text(input).font(.caption).foregroundStyle(.secondary)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(28).frame(width: 620, height: 540)
        .task {
            do {
                let result = try await ConferenceImporter().analyze(input)
                try Task.checkCancellation()
                draft = result
                if result.candidates.count == 1 { selection = [result.candidates[0].id] }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
    private func review(_ draft: ConferenceDraft) {
        if draft.candidates.isEmpty { onReview([draft.deadline], false); return }
        let deadlines = draft.candidates.filter { selection.contains($0.id) }.map { candidate in
            var deadline = draft.deadline
            deadline.id = UUID()
            deadline.date = candidate.date; deadline.kind = candidate.kind
            deadline.hasTime = candidate.hasTime; deadline.timeZoneIdentifier = candidate.timeZone
            deadline.notes = "\(candidate.evidence)\nSource: \(candidate.source.absoluteString)"
            return deadline
        }
        onReview(deadlines, true)
    }
}

struct ConferenceWindowDrop: ViewModifier {
    let importURL: (String) -> Void
    let reportError: (String) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onDrop(of: [.html, .url, .plainText, .image, UTType(importedAs: "com.apple.webarchive"), UTType(importedAs: "WebURLsWithTitlesPboardType")], isTargeted: $targeted, perform: dropped)
            .overlay {
                if targeted {
                    ZStack {
                        Color.accentColor.opacity(0.08)
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                            .padding(8)
                        Label("Drop to import conference", systemImage: "link.badge.plus")
                            .font(.title3.bold()).padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }.allowsHitTesting(false)
                }
            }
    }
    private func dropped(_ providers: [NSItemProvider]) -> Bool {
        let types = ["com.apple.webarchive", "WebURLsWithTitlesPboardType", UTType.html.identifier, UTType.url.identifier, UTType.plainText.identifier]
        let requests = providers.flatMap { provider in
            types.filter { provider.hasItemConformingToTypeIdentifier($0) }.map { (provider, $0) }
        }
        guard !requests.isEmpty else {
            reportError(BrowserLink.imageMessage)
            return true
        }
        let collector = BrowserDropCollector(count: requests.count, importURL: importURL, reportError: reportError)
        // Begin every representation load before returning from the drop callback.
        // A linked icon's HTML href takes priority over its SVG image URL.
        for (provider, type) in requests {
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                let value: String?
                if let url = item as? URL { value = url.absoluteString }
                else if let text = item as? String { value = text }
                else if let data = item as? Data {
                    if type == "com.apple.webarchive" { value = BrowserLink.archiveHTML(data) }
                    else if type == "WebURLsWithTitlesPboardType" { value = BrowserLink.browserURLList(data) }
                    else { value = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) }
                }
                else { value = nil }
                Task { @MainActor in collector.receive(value, html: type == UTType.html.identifier || type == "com.apple.webarchive") }
            }
        }
        return true
    }
}

@MainActor
private final class BrowserDropCollector {
    private var remaining: Int
    private var values: [(text: String, html: Bool)] = []
    private let importURL: (String) -> Void
    private let reportError: (String) -> Void

    init(count: Int, importURL: @escaping (String) -> Void, reportError: @escaping (String) -> Void) {
        remaining = count; self.importURL = importURL; self.reportError = reportError
    }
    func receive(_ text: String?, html: Bool) {
        if let text { values.append((text, html)) }
        remaining -= 1
        guard remaining == 0 else { return }
        let ordered = values.sorted { $0.html && !$1.html }
        guard let url = BrowserLink.preferred(ordered) else {
            reportError("The browser did not supply a conference URL. Drag the conference title or its website link.")
            return
        }
        guard !BrowserLink.isImage(url) else { reportError(BrowserLink.imageMessage); return }
        importURL(url.absoluteString)
    }
}
