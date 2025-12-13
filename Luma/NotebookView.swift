import Combine
import SwiftData
import SwiftUI

struct NotebookView: View {
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    @Query(sort: \NotebookEntry.timestamp, order: .forward)
    private var entries: [NotebookEntry]

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            if entries.isEmpty {
                NotebookEmptyStateView(workspace: workspace)
            } else {
                content
            }
        }
    }

    private var content: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(entries) { entry in
                        NotebookEntryRow(
                            entry: entry,
                            workspace: workspace,
                            selection: $selection
                        ) {
                            addUserNote(after: entry)
                        } deleteAction: {
                            workspace.notifyLocalNotebookEntryDeleted(entry)
                            modelContext.delete(entry)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                }
            }

            Button {
                addUserNote(after: nil)
            } label: {
                Label("New Note", systemImage: "plus")
                    .padding(.horizontal, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding()
            .clipShape(Capsule())
            .shadow(radius: 3)
        }
    }

    private func addUserNote(after entry: NotebookEntry?) {
        let note = NotebookEntry(
            title: "Note",
            details: "",
            binaryData: nil,
            processName: entry?.processName,
            isUserNote: true
        )
        workspace.addNotebookEntry(note, after: entry)
    }
}

struct NotebookEntryRow: View {
    @Bindable var entry: NotebookEntry
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    let addNoteBelow: () -> Void
    let deleteAction: () -> Void

    @FocusState private var isTitleFocused: Bool
    @FocusState private var isBodyFocused: Bool
    @State private var isEditingUserNote: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if entry.isUserNote {
                if isEditingUserNote {
                    editableUserNoteBody
                } else {
                    readOnlyUserNoteBody
                }
            } else {
                systemEntryBody
            }

            if let data = entry.binaryData, !data.isEmpty {
                HexView(data: data)
                    .font(.system(.footnote, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            if entry.isUserNote {
                Button {
                    beginEditing()
                } label: {
                    Label("Edit Note", systemImage: "pencil")
                }
            }

            Button {
                addNoteBelow()
            } label: {
                Label("Insert Note Below", systemImage: "plus")
            }

            Divider()

            Button(role: .destructive) {
                deleteAction()
            } label: {
                Label("Delete Entry", systemImage: "trash")
            }
        }
        .onAppear {
            if entry.isUserNote && entry.details.isEmpty && entry.title == "Note" {
                isEditingUserNote = true
                DispatchQueue.main.async {
                    isTitleFocused = true
                }
            }
        }
        .onChange(of: isTitleFocused) {
            handleFocusChange()
        }
        .onChange(of: isBodyFocused) {
            handleFocusChange()
        }
        .onTapGesture(count: 2) {
            guard entry.isUserNote else { return }
            beginEditing(focusBody: true)
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            if let processName = entry.processName {
                Text(processName)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            if entry.isUserNote {
                Text(entry.title.isEmpty ? "Note" : entry.title)
                    .font(.headline)
                    .lineLimit(1)
                    .textSelection(.enabled)
            } else {
                Text(entry.title)
                    .font(.headline)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer()

            Text(entry.timestamp.formatted())
                .font(.caption2)
                .foregroundStyle(.secondary)

            if entry.isUserNote && !isEditingUserNote {
                Button {
                    beginEditing(focusBody: true)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit Note")
            }
        }
    }

    @ViewBuilder
    private var editableUserNoteBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $entry.title)
                .font(.subheadline.weight(.semibold))
                .focused($isTitleFocused)

            TextEditor(text: $entry.details)
                .font(.system(.body, design: .default))
                .frame(minHeight: 80)
                .focused($isBodyFocused)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2))
                )
        }
    }

    @ViewBuilder
    private var readOnlyUserNoteBody: some View {
        if !entry.details.isEmpty {
            Text(entry.details)
                .font(.body)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var systemEntryBody: some View {
        if let jsValue = entry.jsValue {
            JSInspectValueView(
                value: jsValue,
                sessionID: entry.session!,
                workspace: workspace,
                selection: $selection
            )
        } else if !entry.details.isEmpty {
            Text(entry.details)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func handleFocusChange() {
        if entry.isUserNote,
            isEditingUserNote,
            !isTitleFocused,
            !isBodyFocused
        {
            withAnimation(.easeOut(duration: 0.15)) {
                isEditingUserNote = false
                workspace.notifyLocalNotebookEntryUpdated(entry)
            }
        }
    }

    private func beginEditing(focusBody: Bool = false) {
        guard entry.isUserNote else { return }

        withAnimation(.easeInOut(duration: 0.15)) {
            isEditingUserNote = true
        }

        DispatchQueue.main.async {
            if focusBody {
                isBodyFocused = true
            } else {
                isTitleFocused = true
            }
        }
    }
}

private let instructionsMaxWidth: CGFloat = 350

struct NotebookEmptyStateView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        GeometryReader { geo in
            VStack {
                Spacer(minLength: 0)

                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Image(systemName: "book.pages")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)

                        Text("Notebook")
                            .font(.title2.weight(.semibold))

                        Text("Capture interesting findings here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    HStack {
                        Spacer(minLength: 0)

                        VStack(alignment: .leading, spacing: 8) {
                            Group {
                                Text("1. Use the ")
                                    + Text(Image(systemName: "target"))
                                    + Text(" button to attach to a running app or process.")
                            }
                            .fixedSize(horizontal: false, vertical: true)

                            Group {
                                Text("2. Then use the ")
                                    + Text(Image(systemName: "waveform.path.ecg"))
                                    + Text(" button to add instruments.")
                            }
                            .fixedSize(horizontal: false, vertical: true)

                            Text("3. Pin any event from the bottom event stream to save it here.")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.callout)
                        .frame(maxWidth: instructionsMaxWidth, alignment: .leading)

                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
