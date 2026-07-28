import SwiftUI
import SwiftyPharo

/// The class heading Glamorous Toolkit's coder shows: where the class sits,
/// above its views.
struct PharoClassHeader: View {
    let info: PharoClassBrowserInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Class")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(info.name)
                .font(.title3.bold())
                .accessibilityIdentifier("pharo.class.name")

            HStack(spacing: 16) {
                metaItem("Superclass", info.superclass)
                metaItem("Package", info.package)
                if !info.tag.isEmpty {
                    metaItem("Tag", info.tag)
                }
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    private func metaItem(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
        }
        .font(.caption)
    }
}

/// The methods of a class, each opening to its source, the way the coder lists
/// them. It stands in for the plain list our inspector would otherwise draw for
/// the Methods view, so drilling and browsing meet in one place.
struct PharoMethodList: View {
    let methods: [PharoMethodInfo]
    let runtime: PharoRuntime
    let classObject: PharoObject
    let onSelect: (PharoObject) -> Void

    @State private var expanded: Set<String> = []
    @State private var focused: UUID?
    @State private var reveal: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(methods) { method in
                        PharoMethodRow(
                            method: method,
                            runtime: runtime,
                            classObject: classObject,
                            isExpanded: expanded.contains(method.id),
                            focused: $focused,
                            toggleExpanded: { toggle(method.id) },
                            onSelect: onSelect)
                        .id(method.id)
                        Divider()
                    }
                }
            }
            .onChange(of: reveal) { _, target in
                guard let target else { return }
                reveal = nil
                // The opened method grows this turn, so scroll to it once it
                // has laid out.
                DispatchQueue.main.async { proxy.scrollTo(target) }
            }
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
            reveal = id
        }
    }
}

/// One method: its name and tags, opening to its source in the same editor the
/// snippets use, so a class it names can be drilled from here too.
private struct PharoMethodRow: View {
    let method: PharoMethodInfo
    let runtime: PharoRuntime
    let classObject: PharoObject
    let isExpanded: Bool
    @Binding var focused: UUID?
    let toggleExpanded: () -> Void
    let onSelect: (PharoObject) -> Void

    @State private var id = UUID()
    @State private var source: String
    @State private var savedSource: String
    @State private var saveError: String?
    @State private var openedClasses: [String: PharoObject] = [:]

    init(
        method: PharoMethodInfo,
        runtime: PharoRuntime,
        classObject: PharoObject,
        isExpanded: Bool,
        focused: Binding<UUID?>,
        toggleExpanded: @escaping () -> Void,
        onSelect: @escaping (PharoObject) -> Void
    ) {
        self.method = method
        self.runtime = runtime
        self.classObject = classObject
        self.isExpanded = isExpanded
        _focused = focused
        self.toggleExpanded = toggleExpanded
        self.onSelect = onSelect
        _source = State(initialValue: method.source)
        _savedSource = State(initialValue: method.source)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ribbon
            VStack(alignment: .leading, spacing: 0) {
                heading
                if isExpanded {
                    editor
                }
            }
        }
        .onChange(of: isExpanded) {
            if isExpanded {
                focused = id
            } else if isFocused {
                focused = nil
            }
        }
    }

    private var ribbon: some View {
        Rectangle()
            .fill(isFocused ? Color.fridaBrand : .clear)
            .frame(width: 3)
            .contentShape(Rectangle())
            .onTapGesture {
                if isExpanded {
                    toggleExpanded()
                }
            }
    }

    private var heading: some View {
        Button(action: toggleExpanded) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(method.selector)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if isClassified {
                    tag(method.category).frame(maxWidth: 130, alignment: .trailing)
                }
                tag(method.side)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15))
            .clipShape(Capsule())
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 4) {
            PharoSourceEditor(
                id: id,
                source: $source,
                focused: $focused,
                runtime: runtime,
                marks: PharoSnippetMarks(openedClasses: openedClasses, hasResult: false),
                onToggleClass: toggleClass,
                onOpen: onSelect,
                onOpenResult: {})

            if isDirty {
                HStack(spacing: 6) {
                    if let saveError {
                        Text(saveError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button(action: save) {
                        Image(systemName: "checkmark")
                            .font(.caption)
                            .frame(width: 16, height: 12)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut("s", modifiers: .command)
                    .help("Save")
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    private var isDirty: Bool {
        source != savedSource
    }

    private func save() {
        Task {
            do {
                _ = try await runtime.compileMethod(
                    in: classObject,
                    side: method.side,
                    category: method.category,
                    source: source)
                savedSource = source
                saveError = nil
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    private var isFocused: Bool {
        focused == id
    }

    /// Pharo's placeholder category is not one worth a tag of its own.
    private var isClassified: Bool {
        !method.category.isEmpty && method.category != "as yet unclassified"
    }

    private func toggleClass(_ name: String) {
        guard openedClasses[name] == nil else {
            openedClasses[name] = nil
            return
        }

        Task { openedClasses[name] = try? await runtime.evaluate(name) }
    }
}
