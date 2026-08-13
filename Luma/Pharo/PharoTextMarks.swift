import Combine
import SwiftUI
import SwiftyPharo

/// What a snippet marks inline. The body each one opens lives below the editor,
/// not in the text, so only these fixed-size triggers are attachments.
enum PharoMarkContent {
    case classTriangle(String)
    case methodTriangle(String)
    case undeclaredWrench(String)
    case result
    case errorDot(String)

    /// The result dot sits at the very end, after any mark sharing its spot.
    var insertionOrder: Int {
        switch self {
        case .result: 2
        default: 0
        }
    }
}

struct PharoPlacedMark: Hashable {
    let sourceOffset: Int
    let content: PharoMarkContent
}

enum PharoBodyItem: Identifiable {
    case classBody(PharoClassMarkModel)
    case methodBody(PharoMethodMarkModel)
    case newClass(PharoUndeclaredMarkModel)

    var id: String {
        switch self {
        case .classBody(let model): "class:\(model.name)"
        case .methodBody(let model): "method:\(model.reference.id)"
        case .newClass(let model): "newclass:\(model.variable.id)"
        }
    }
}

final class PharoMarkHostingView: PlatformView {
    private let hosting: PlatformHostingView

    init(content: some View) {
        hosting = PlatformHostingView(rootView: content)
        super.init(frame: .zero)
        addSubview(hosting)
    }

    #if canImport(AppKit)
        override func layout() {
            super.layout()
            hosting.frame = bounds
        }
    #else
        override func layoutSubviews() {
            super.layoutSubviews()
            hosting.frame = bounds
        }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PharoMarkHostingView is not loaded from a nib")
    }
}

/// The attachment only holds the line open for its mark: it draws nothing, and
/// the mark's view is placed over it as a real subview. A text view builds an
/// attachment's own view lazily, and only once it is first responder, so a
/// loaded snippet's marks would otherwise stay placeholders until a click.
nonisolated final class PharoMarkAttachment: NSTextAttachment, @unchecked Sendable {
    let content: PharoMarkContent
    let markView: PlatformView

    init(content: PharoMarkContent, markView: PlatformView) {
        self.content = content
        self.markView = markView
        super.init(data: nil, ofType: nil)
        image = .pharoSpacer(of: .zero)
    }

    func resize(to size: CGRect) {
        bounds = size
        // An empty image of the wanted size holds the space and draws nothing; an
        // attachment with no contents would draw the placeholder document icon.
        image = .pharoSpacer(of: size.size)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PharoMarkAttachment is not loaded from a nib")
    }
}

/// A body the reader opened. Its own line is held open to the body's height by
/// that line's paragraph style, and the body is drawn over that line as a real
/// subview -- the way the marks are -- so it fills the visible width while long
/// lines scroll under it. The attachment itself only anchors the line.
nonisolated final class PharoBodyAttachment: NSTextAttachment, @unchecked Sendable {
    let id: String
    let bodyView: PlatformHostingView
    var height: CGFloat = 1

    init(id: String, bodyView: PlatformHostingView) {
        self.id = id
        self.bodyView = bodyView
        super.init(data: nil, ofType: nil)
        image = .pharoSpacer(of: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PharoBodyAttachment is not loaded from a nib")
    }
}

extension PlatformImage {
    nonisolated static func pharoSpacer(of size: CGSize) -> PlatformImage {
        #if canImport(AppKit)
            return NSImage(size: size)
        #else
            return UIGraphicsImageRenderer(size: size).image { _ in }
        #endif
    }
}

final class PharoResultMarkModel: ObservableObject {
    @Published var hasResult = false
    var open: () -> Void = {}
}

final class PharoClassMarkModel: ObservableObject {
    let runtime: PharoRuntime
    let name: String
    let onToggle: () -> Void
    let onOpen: (PharoObject) -> Void
    @Published var opened: PharoObject?

    init(
        runtime: PharoRuntime,
        name: String,
        opened: PharoObject?,
        onToggle: @escaping () -> Void,
        onOpen: @escaping (PharoObject) -> Void
    ) {
        self.runtime = runtime
        self.name = name
        self.opened = opened
        self.onToggle = onToggle
        self.onOpen = onOpen
    }
}

/// A method a send resolves to, opened below the editor. Its source comes with
/// the reference, so opening one asks the image for nothing.
final class PharoMethodMarkModel: ObservableObject {
    let runtime: PharoRuntime
    let reference: PharoMethodReference
    let onToggle: () -> Void
    let onOpen: (PharoObject) -> Void
    @Published var opened = false

    init(
        runtime: PharoRuntime,
        reference: PharoMethodReference,
        onToggle: @escaping () -> Void,
        onOpen: @escaping (PharoObject) -> Void
    ) {
        self.runtime = runtime
        self.reference = reference
        self.onToggle = onToggle
        self.onOpen = onOpen
    }
}

/// An undeclared name's fixes, offered from the wrench the coder puts after it,
/// and the fields of the class-definition form the "Create class" fix opens.
final class PharoUndeclaredMarkModel: ObservableObject {
    let variable: PharoUndeclaredVariable
    @Published var isDefining = false
    @Published var name: String
    @Published var superclassName = "Object"
    @Published var package = "Playground"
    @Published var tag = ""
    @Published var instanceVariables = ""
    @Published var classVariables = ""
    @Published var classInstanceVariables = ""
    var onReplace: (String) -> Void = { _ in }
    var onConfirm: () -> Void = {}
    var onChanged: () -> Void = {}

    init(variable: PharoUndeclaredVariable) {
        self.variable = variable
        self.name = variable.name
    }

    func startDefining() {
        isDefining = true
        onChanged()
    }

    func cancel() {
        isDefining = false
        onChanged()
    }
}

struct PharoClassTriangle: View {
    @ObservedObject var model: PharoClassMarkModel

    @State private var isPointedAt = false

    var body: some View {
        Button(action: model.onToggle) {
            Image(systemName: model.opened != nil ? "chevron.down.circle.fill" : "chevron.right.circle")
                .font(.system(size: 11))
                .foregroundStyle(isPointedAt || model.opened != nil ? Color.fridaBrand : .secondary)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { isPointedAt = $0 }
        .help(model.opened != nil ? "Hide" : "Show")
    }
}

struct PharoClassBody: View {
    @ObservedObject var model: PharoClassMarkModel

    var body: some View {
        if let opened = model.opened {
            PharoObjectColumn(
                runtime: model.runtime,
                object: opened,
                onSelect: model.onOpen,
                onClose: model.onToggle)
            .pharoPane()
        }
    }
}

struct PharoMethodTriangle: View {
    @ObservedObject var model: PharoMethodMarkModel

    @State private var isPointedAt = false

    var body: some View {
        Button(action: model.onToggle) {
            Image(systemName: model.opened ? "chevron.down.circle.fill" : "chevron.right.circle")
                .font(.system(size: 11))
                .foregroundStyle(isPointedAt || model.opened ? Color.fridaBrand : .secondary)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { isPointedAt = $0 }
        .help(model.opened ? "Hide" : "Show")
    }
}

struct PharoMethodBody: View {
    @ObservedObject var model: PharoMethodMarkModel

    var body: some View {
        if model.opened {
            PharoMethodEditor(
                reference: model.reference,
                runtime: model.runtime,
                onSelect: model.onOpen)
            .pharoPane()
        }
    }
}

struct PharoUndeclaredWrench: View {
    @ObservedObject var model: PharoUndeclaredMarkModel

    @State private var isPointedAt = false

    var body: some View {
        Menu {
            Section("Variable is undeclared.") {
                Button("Create class \(model.variable.name)", action: model.startDefining)
                ForEach(model.variable.suggestions, id: \.self) { name in
                    Button("Use \(name) instead of \(model.variable.name)") { model.onReplace(name) }
                }
            }
        } label: {
            Image(systemName: "wrench.adjustable")
                .font(.system(size: 10))
                .foregroundStyle(isPointedAt ? Color.fridaBrand : .secondary)
        }
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { isPointedAt = $0 }
        .help("Fix")
    }
}

struct PharoNewClassBody: View {
    @ObservedObject var model: PharoUndeclaredMarkModel

    var body: some View {
        if model.isDefining {
            PharoNewClassForm(model: model).pharoPane()
        }
    }
}

private struct PharoNewClassForm: View {
    @ObservedObject var model: PharoUndeclaredMarkModel

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
            field("Name", text: $model.name)
            field("Superclass", text: $model.superclassName)
            field("Package", text: $model.package)
            field("Tag", text: $model.tag)
            field("Instance-side slots", text: $model.instanceVariables)
            field("Class-side slots", text: $model.classInstanceVariables)
            field("Class vars", text: $model.classVariables)
            GridRow {
                Color.clear.frame(width: 0, height: 0)
                HStack(spacing: 6) {
                    Button(action: model.onConfirm) {
                        Image(systemName: "checkmark").frame(width: 16, height: 12)
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .help("Create")
                    Button(action: model.cancel) {
                        Image(systemName: "xmark").frame(width: 16, height: 12)
                    }
                    .help("Cancel")
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
            }
        }
        .padding(10)
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        GridRow {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
        }
    }
}

struct PharoResultDot: View {
    @ObservedObject var model: PharoResultMarkModel

    @State private var isPointedAt = false

    var body: some View {
        Button(action: model.open) {
            Circle()
                .fill(isPointedAt ? Color.fridaBrand : Color.secondary)
                .frame(width: 8, height: 8)
                .opacity(model.hasResult ? 1 : 0)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { isPointedAt = $0 }
        .help("Inspect the result")
    }
}

struct PharoErrorDot: View {
    let message: String

    @State private var isPointedAt = false
    @State private var isShowingMessage = false

    var body: some View {
        Button(action: { isShowingMessage = true }) {
            Circle()
                .fill(isPointedAt ? Color.red.opacity(0.8) : Color.red)
                .frame(width: 11, height: 11)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { isPointedAt = $0 }
        .help(message)
        .popover(isPresented: $isShowingMessage) {
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: 320)
        }
    }
}

extension PharoMarkContent: Hashable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.classTriangle(let a), .classTriangle(let b)):
            a == b
        case (.methodTriangle(let a), .methodTriangle(let b)):
            a == b
        case (.undeclaredWrench(let a), .undeclaredWrench(let b)):
            a == b
        case (.result, .result):
            true
        case (.errorDot(let a), .errorDot(let b)):
            a == b
        default:
            false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .classTriangle(let name):
            hasher.combine(0)
            hasher.combine(name)
        case .methodTriangle(let key):
            hasher.combine(3)
            hasher.combine(key)
        case .undeclaredWrench(let key):
            hasher.combine(5)
            hasher.combine(key)
        case .result:
            hasher.combine(2)
        case .errorDot(let message):
            hasher.combine(7)
            hasher.combine(message)
        }
    }
}
