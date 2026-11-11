import SwiftUI

struct DeadlineBatch: Identifiable {
    let id = UUID()
    let deadlines: [Deadline]
}

struct DeadlineBatchEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var deadlines: [Deadline]
    let kinds: [String]
    let onSave: ([Deadline]) -> Void
    @State private var index = 0
    var body: some View {
        VStack(spacing: 0) {
            Text("Review deadline \(index + 1) of \(deadlines.count)")
                .font(.headline).padding(.top, 20)
            Text("All selected deadlines will be saved together after the final review.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            DeadlineEditor(deadline: deadlines[index], kinds: kinds, dismissOnSave: false,
                           saveLabel: index + 1 == deadlines.count ? "Save \(deadlines.count) deadlines" : "Next deadline") { deadline in
                deadlines[index] = deadline
                if index + 1 < deadlines.count { index += 1 }
                else { onSave(deadlines); dismiss() }
            }.id(index)
        }
    }
}
