import Adw
import Foundation
import Gtk
import LumaCore

@MainActor
final class CustomInstrumentCompatibilityDialog {
    private let engine: Engine
    private var def: CustomInstrumentDef
    private let dialog: Adw.Dialog

    private var draftPlatforms: Set<String>
    private var draftOSIDs: Set<String>
    private var draftArchs: Set<String>

    private static let knownPlatforms = ["windows", "darwin", "linux", "freebsd", "qnx", "barebone"]
    private static let knownOSIDs = ["windows", "macos", "linux", "ios", "watchos", "tvos", "visionos", "android", "freebsd", "qnx"]
    private static let knownArchs = ["ia32", "x64", "arm", "arm64", "mips"]

    init(engine: Engine, def: CustomInstrumentDef) {
        self.engine = engine
        self.def = def
        self.draftPlatforms = def.compatibility.platforms ?? []
        self.draftOSIDs = def.compatibility.osIDs ?? []
        self.draftArchs = def.compatibility.archs ?? []

        dialog = Adw.Dialog()
        dialog.set(title: "Compatibility")
        dialog.set(followsContentSize: true)

        layout()
    }

    func present(parent: Gtk.Window) {
        Self.retain(self, dialog: dialog)
        MonacoEditor.suspendOverlays()
        dialog.onClosed { _ in
            MainActor.assumeIsolated {
                MonacoEditor.resumeOverlays()
            }
        }
        dialog.present(parent: parent)
    }

    private func layout() {
        let content = Box(orientation: .vertical, spacing: 12)
        content.marginStart = 16
        content.marginEnd = 16
        content.marginTop = 16
        content.marginBottom = 16
        content.setSizeRequest(width: 520, height: -1)

        let intro = Label(str: "Restrict which devices this instrument can be added to. Leave a section empty to allow any value for that axis.")
        intro.add(cssClass: "dim-label")
        intro.wrap = true
        intro.xalign = 0
        intro.maxWidthChars = 60
        content.append(child: intro)

        content.append(child: axisSection(title: "Platforms", known: Self.knownPlatforms, displayName: InstrumentCompatibility.platformDisplayName, axis: .platforms))
        content.append(child: axisSection(title: "Operating Systems", known: Self.knownOSIDs, displayName: InstrumentCompatibility.osDisplayName, axis: .osIDs))
        content.append(child: axisSection(title: "Architectures", known: Self.knownArchs, displayName: InstrumentCompatibility.archDisplayName, axis: .archs))

        let header = Adw.HeaderBar()
        let saveButton = Button(label: "Save")
        saveButton.add(cssClass: "suggested-action")
        saveButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.commit() }
        }
        header.packEnd(child: saveButton)

        let toolbarView = Adw.ToolbarView()
        toolbarView.addTopBar(widget: header)
        toolbarView.set(content: content)

        dialog.set(child: toolbarView)
    }

    private enum Axis { case platforms, osIDs, archs }

    private func axisSection(title: String, known: [String], displayName: (String) -> String, axis: Axis) -> Box {
        let section = Box(orientation: .vertical, spacing: 6)

        let titleLabel = Label(str: title)
        titleLabel.add(cssClass: "heading")
        titleLabel.halign = .start
        section.append(child: titleLabel)

        let grid = Grid()
        grid.columnSpacing = 12
        grid.rowSpacing = 4

        let columns = 4
        for (index, value) in orderedValues(known: known, axis: axis).enumerated() {
            let check = CheckButton(label: displayName(value))
            check.active = selection(for: axis).contains(value)
            check.onToggled { [weak self] ref in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if ref.active {
                        self.insert(value, into: axis)
                    } else {
                        self.remove(value, from: axis)
                    }
                }
            }
            grid.attach(child: check, column: index % columns, row: index / columns, width: 1, height: 1)
        }
        section.append(child: grid)

        return section
    }

    private func orderedValues(known: [String], axis: Axis) -> [String] {
        known + selection(for: axis).subtracting(known).sorted()
    }

    private func selection(for axis: Axis) -> Set<String> {
        switch axis {
        case .platforms: return draftPlatforms
        case .osIDs: return draftOSIDs
        case .archs: return draftArchs
        }
    }

    private func insert(_ value: String, into axis: Axis) {
        switch axis {
        case .platforms: draftPlatforms.insert(value)
        case .osIDs: draftOSIDs.insert(value)
        case .archs: draftArchs.insert(value)
        }
    }

    private func remove(_ value: String, from axis: Axis) {
        switch axis {
        case .platforms: draftPlatforms.remove(value)
        case .osIDs: draftOSIDs.remove(value)
        case .archs: draftArchs.remove(value)
        }
    }

    private func commit() {
        var updated = def
        updated.compatibility = InstrumentCompatibility(
            platforms: draftPlatforms,
            osIDs: draftOSIDs,
            archs: draftArchs
        )
        let engine = self.engine
        let dialog = self.dialog
        Task { @MainActor in
            await engine.updateCustomInstrument(updated)
            _ = dialog.close()
        }
    }

    private static func retain(_ owner: CustomInstrumentCompatibilityDialog, dialog: Adw.Dialog) {
        let key = ObjectIdentifier(dialog)
        retained[key] = owner
        dialog.onClosed { _ in
            MainActor.assumeIsolated {
                _ = retained.removeValue(forKey: key)
            }
        }
    }

    private static var retained: [ObjectIdentifier: CustomInstrumentCompatibilityDialog] = [:]
}
