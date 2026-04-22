import Combine
import LumaCore
import SwiftUI

struct NotebookView: View {
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var horizontalInset: CGFloat { horizontalSizeClass == .compact ? 6 : 16 }
    #else
    private var horizontalInset: CGFloat { 16 }
    #endif

    private var entries: [LumaCore.NotebookEntry] {
        workspace.engine.notebookEntries.sorted { a, b in
            if a.position != b.position { return a.position < b.position }
            return a.id.uuidString < b.id.uuidString
        }
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                NotebookEmptyStateView(workspace: workspace, onAddNote: { addUserNote(after: nil) })
            } else {
                content
            }
        }
    }

    private var content: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        let ordered = entries
                        TopDropZone(workspace: workspace, firstEntry: ordered.first)
                            .padding(.horizontal, horizontalInset)
                        ForEach(Array(ordered.enumerated()), id: \.element.id) { index, entry in
                            NotebookEntryRow(
                                entry: entry,
                                previous: index > 0 ? ordered[index - 1] : nil,
                                next: index < ordered.count - 1 ? ordered[index + 1] : nil,
                                workspace: workspace,
                                selection: $selection,
                                onEditingChanged: { editing in
                                    if editing {
                                        editingEntryIDs.insert(entry.id)
                                    } else {
                                        editingEntryIDs.remove(entry.id)
                                    }
                                }
                            ) {
                                addUserNote(after: entry)
                            } deleteAction: {
                                workspace.engine.deleteNotebookEntry(entry)
                            }
                            .id(entry.id)
                        }
                        .padding(.horizontal, horizontalInset)
                        Color.clear
                            .frame(height: 80)
                            .id("notebook-bottom-anchor")
                    }
                }
                .onChange(of: lastInsertedID) { _, newID in
                    guard newID != nil else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo("notebook-bottom-anchor", anchor: .bottom)
                    }
                }
                .onChange(of: entries.map(\.id)) { _, newIDs in
                    editingEntryIDs.formIntersection(Set(newIDs))
                }
            }

            Button {
                addUserNote(after: nil)
            } label: {
                Label("New Note", systemImage: "plus")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            #if canImport(UIKit)
            .controlSize(.regular)
            #else
            .controlSize(.small)
            #endif
            .shadow(radius: 3, y: 1)
            .padding()
            .opacity(isAnyEditing ? 0 : 1)
            .allowsHitTesting(!isAnyEditing)
            .animation(.easeInOut(duration: 0.15), value: isAnyEditing)
        }
    }

    @State private var editingEntryIDs: Set<UUID> = []

    private var isAnyEditing: Bool { !editingEntryIDs.isEmpty }

    @State private var lastInsertedID: UUID?

    private func addUserNote(after entry: LumaCore.NotebookEntry?) {
        let note = LumaCore.NotebookEntry(
            kind: .note,
            title: "",
            details: "",
            binaryData: nil,
            processName: entry?.processName
        )
        workspace.engine.addNotebookEntry(note, after: entry)
        lastInsertedID = note.id
    }
}

/// Thin drop strip above the first entry so drags can actually land at
/// position 0. The per-row `.dropDestination` only fires inside the
/// row's frame; drops into the empty space above the first row used
/// to fall on the floor.
private struct TopDropZone: View {
    @ObservedObject var workspace: Workspace
    let firstEntry: LumaCore.NotebookEntry?
    @State private var isTargeted = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 6)
            .overlay(alignment: .bottom) {
                if isTargeted {
                    Color.accentColor.frame(height: 2)
                }
            }
            .dropDestination(for: String.self) { items, _ in
                guard let first = items.first,
                      let sourceID = UUID(uuidString: first),
                      let source = workspace.engine.notebookEntries.first(where: { $0.id == sourceID })
                else { return false }
                if source.id == firstEntry?.id { return false }
                workspace.engine.reorderNotebookEntry(
                    source,
                    between: nil,
                    and: firstEntry,
                )
                return true
            } isTargeted: { isTargeted = $0 }
    }
}

struct NotebookEntryRow: View {
    let entry: LumaCore.NotebookEntry
    let previous: LumaCore.NotebookEntry?
    let next: LumaCore.NotebookEntry?
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    let onEditingChanged: (Bool) -> Void
    let addNoteBelow: () -> Void
    let deleteAction: () -> Void

    @FocusState private var isTitleFocused: Bool
    @FocusState private var isBodyFocused: Bool
    @State private var isEditingUserNote: Bool = false
    @State private var editTitle: String = ""
    @State private var editDetails: String = ""
    @State private var dropHighlight: DropHighlight = .none
    @State private var rowHeight: CGFloat = 0

    private enum DropHighlight { case none, above, below }
    private struct RowHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

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
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: RowHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(RowHeightKey.self) { rowHeight = $0 }
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
            if isNote && entry.details.isEmpty && entry.title.isEmpty {
                isEditingUserNote = true
                DispatchQueue.main.async {
                    isTitleFocused = true
                }
            }
        }
        .onChange(of: isEditingUserNote) { _, newValue in
            onEditingChanged(newValue)
        }
        .onDisappear {
            if isEditingUserNote {
                onEditingChanged(false)
            }
        }
        .onTapGesture(count: 2) {
            guard isNote else { return }
            beginEditing(focusBody: true)
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            editorStack

            if let processName = entry.processName {
                Text(processName)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            if !(isNote && isEditingUserNote) {
                Text(isNote && entry.title.isEmpty ? "Note" : entry.title)
                    .font(.headline)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }

            NotebookTimestampLabel(date: entry.timestamp)
                .help(entry.timestamp.formatted())
        }
    }

    @ViewBuilder
    private var editorStack: some View {
        if !entry.editors.isEmpty {
            HStack(spacing: -8) {
                ForEach(Array(entry.editors.enumerated()), id: \.element.id) { index, editor in
                    editorAvatar(editor)
                        .zIndex(Double(entry.editors.count - index))
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
        .frame(width: 20, height: 20)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.platformWindowBackground, lineWidth: 2))
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

        let midpoint = rowHeight > 0 ? rowHeight / 2 : 0
        let dropAbove = location.y < midpoint
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
                .onSubmit { saveEdits() }

            TextEditor(text: $editDetails)
                .font(.system(.body, design: .default))
                .frame(minHeight: 80)
                .focused($isBodyFocused)
                .overlay(alignment: .topLeading) {
                    if editDetails.isEmpty {
                        Text("Write something\u{2026}")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2))
                )

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { cancelEdits() }
                Button("Save") { saveEdits() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
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
            .font(.system(.footnote, design: .monospaced))
        } else if !entry.details.isEmpty {
            Text(entry.details)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func saveEdits() {
        var updated = entry
        updated.title = editTitle
        updated.details = editDetails
        withAnimation(.easeOut(duration: 0.15)) {
            isEditingUserNote = false
        }
        workspace.engine.updateNotebookEntry(updated)
    }

    private func cancelEdits() {
        if isFreshPlaceholder {
            workspace.engine.deleteNotebookEntry(entry)
            return
        }

        editTitle = entry.title
        editDetails = entry.details
        withAnimation(.easeOut(duration: 0.15)) {
            isEditingUserNote = false
        }
    }

    private var isFreshPlaceholder: Bool {
        entry.title.isEmpty && entry.details.isEmpty
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
    let onAddNote: () -> Void

    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompact: Bool { horizontalSizeClass == .compact }
    #else
    private var isCompact: Bool { false }
    #endif

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

                    if !isCompact {
                        walkthrough
                    }

                    Button(action: onAddNote) {
                        Label("New Note", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var walkthrough: some View {
        HStack {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 8) {
                walkthroughStep(
                    number: 1,
                    text: Text("Use the \(Image(systemName: "target")) button to attach to a running app or process.")
                )
                walkthroughStep(
                    number: 2,
                    text: Text("Then use the \(Image(systemName: "waveform.path.ecg")) button to add instruments.")
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

struct NotebookTimestampLabel: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(NotebookTimestamp.string(from: date, now: context.date))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }
}
