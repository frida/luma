import SwiftUI

struct CustomInstrumentFilePathPopover: View {
    let title: String
    let hint: String
    let commitLabel: String
    @Binding var draft: String
    let problem: String?
    let canCommit: Bool
    let onCommit: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("path/to/file.ts", text: $draft)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .onSubmit { if canCommit { onCommit() } }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(commitLabel, action: onCommit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
            }
        }
        .padding(12)
        .popoverFormSheet(width: 360)
    }
}
