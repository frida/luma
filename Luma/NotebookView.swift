import Combine
import LumaCore
import SwiftUI

struct NotebookView: View {
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    private var entries: [LumaCore.NotebookEntry] {
        workspace.engine.notebookEntries.sorted { a, b in
            if a.position != b.position { return a.position < b.position }
            return a.id.uuidString < b.id.uuidString
        }
    }

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
                    let ordered = entries
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { index, entry in
                        NotebookEntryRow(
                            entry: entry,
                            previous: index > 0 ? ordered[index - 1] : nil,
                            next: index < ordered.count - 1 ? ordered[index + 1] : nil,
                            workspace: workspace,
                            selection: $selection
                        ) {
                            addUserNote(after: entry)
                        } deleteAction: {
                            workspace.engine.deleteNotebookEntry(entry)
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

    private func addUserNote(after entry: LumaCore.NotebookEntry?) {
        let note = LumaCore.NotebookEntry(
            kind: .note,
            title: "Note",
            details: "",
            binaryData: nil,
            processName: entry?.processName
        )
        workspace.engine.addNotebookEntry(note, after: entry)
    }
}

struct NotebookEntryRow: View {
    let entry: LumaCore.NotebookEntry
    let previous: LumaCore.NotebookEntry?
    let next: LumaCore.NotebookEntry?
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    let addNoteBelow: () -> Void
    let deleteAction: () -> Void

    @FocusState private var isTitleFocused: Bool
    @FocusState private var isBodyFocused: Bool
    @State private var isEditingUserNote: Bool = false
    @State private var editTitle: String = ""
    @State private var editDetails: String = ""
    @State private var dropHighlight: DropHighlight = .none

    private enum DropHighlight { case none, above, below }

    private var isNote: Bool { entry.kind == .note }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if isNote {
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
        .overlay(alignment: .top) {
            if dropHighlight == .above {
                Color.accentColor.frame(height: 2)
            }
        }
        .overlay(alignment: .bottom) {
            if dropHighlight == .below {
                Color.accentColor.frame(height: 2)
            }
        }
        .draggable(entry.id.uuidString)
        .dropDestination(for: String.self) { items, location in
            handleDrop(items: items, location: location)
        } isTargeted: { targeted in
            if !targeted { dropHighlight = .none }
        }
        .contextMenu {
            if isNote {
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
            editTitle = entry.title
            editDetails = entry.details
            if isNote && entry.details.isEmpty && entry.title == "Note" {
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
            guard isNote else { return }
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

            Text(isNote && entry.title.isEmpty ? "Note" : entry.title)
                .font(.headline)
                .lineLimit(1)
                .textSelection(.enabled)

            Spacer()

            editorStack

            Text(entry.timestamp.formatted())
                .font(.caption2)
                .foregroundStyle(.secondary)

            if isNote && !isEditingUserNote {
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
    private var editorStack: some View {
        if !entry.editors.isEmpty {
            HStack(spacing: -6) {
                ForEach(entry.editors, id: \.id) { editor in
                    editorAvatar(editor)
                }
            }
        }
    }

    private func editorAvatar(_ editor: LumaCore.NotebookEntry.Author) -> some View {
        let name = editor.name.isEmpty ? "@\(editor.id)" : editor.name
        return AsyncImage(url: URL(string: editor.avatarURL)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 18, height: 18)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color(.windowBackgroundColor), lineWidth: 1.5))
        .help(name)
        .onTapGesture {
            if let url = URL(string: "https://github.com/\(editor.id)") {
                Platform.openURL(url)
            }
        }
    }

    private func handleDrop(items: [String], location: CGPoint) -> Bool {
        defer { dropHighlight = .none }
        guard let first = items.first,
            let sourceID = UUID(uuidString: first),
            sourceID != entry.id
        else { return false }
        guard let source = workspace.engine.notebookEntries.first(where: { $0.id == sourceID })
        else { return false }

        let ordered = workspace.engine.notebookEntries.sorted { a, b in
            if a.position != b.position { return a.position < b.position }
            return a.id.uuidString < b.id.uuidString
        }
        guard let targetIndex = ordered.firstIndex(where: { $0.id == entry.id }) else { return false }

        let dropAbove = location.y < 0
        let neighborA: LumaCore.NotebookEntry?
        let neighborB: LumaCore.NotebookEntry?
        if dropAbove {
            neighborA = targetIndex > 0 ? ordered[targetIndex - 1] : nil
            neighborB = ordered[targetIndex]
        } else {
            neighborA = ordered[targetIndex]
            neighborB = targetIndex < ordered.count - 1 ? ordered[targetIndex + 1] : nil
        }
        // Ignore no-op drags that would land back where the entry already is.
        if neighborA?.id == source.id || neighborB?.id == source.id { return false }

        workspace.engine.reorderNotebookEntry(source, between: neighborA, and: neighborB)
        return true
    }

    @ViewBuilder
    private var editableUserNoteBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $editTitle)
                .font(.subheadline.weight(.semibold))
                .focused($isTitleFocused)

            TextEditor(text: $editDetails)
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
                sessionID: entry.sessionID ?? UUID(),
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
        if isNote,
            isEditingUserNote,
            !isTitleFocused,
            !isBodyFocused
        {
            withAnimation(.easeOut(duration: 0.15)) {
                isEditingUserNote = false
                commitEdits()
            }
        }
    }

    private func commitEdits() {
        var updated = entry
        updated.title = editTitle
        updated.details = editDetails
        workspace.engine.updateNotebookEntry(updated)
    }

    private func beginEditing(focusBody: Bool = false) {
        guard isNote else { return }
        editTitle = entry.title
        editDetails = entry.details

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

private let instructionsMaxWidth: CGFloat = 440

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
                            walkthroughStep(
                                number: 1,
                                text: Text("Use the ")
                                    + Text(Image(systemName: "target"))
                                    + Text(" button to attach to a running app or process.")
                            )
                            walkthroughStep(
                                number: 2,
                                text: Text("Then use the ")
                                    + Text(Image(systemName: "waveform.path.ecg"))
                                    + Text(" button to add instruments.")
                            )
                            walkthroughStep(
                                number: 3,
                                text: Text("Pin any event from the bottom event stream to save it here.")
                            )
                        }
                        .font(.callout)
                        .frame(maxWidth: instructionsMaxWidth, alignment: .leading)
                        .padding(.leading, 72)

                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @ViewBuilder
    private func walkthroughStep(number: Int, text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            text
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
