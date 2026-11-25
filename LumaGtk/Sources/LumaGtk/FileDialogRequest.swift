import CGtk
import Foundation
import GIO
import Gtk

@MainActor
final class FileDialogRequest {
    enum Choice {
        case saveAs
        case folder
        case files
        case folders
    }

    private let choice: Choice
    private let dialog = FileDialog()
    private let cancellable: GIO.Cancellable?
    private let completion: ([String]) -> Void

    static func present(_ choice: Choice, title: String, acceptLabel: String? = nil, initialName: String? = nil, mediaType: String? = nil,
                        cancellable: GIO.Cancellable? = nil, parent: Gtk.Window, completion: @escaping ([String]) -> Void) {
        let request = FileDialogRequest(choice: choice, cancellable: cancellable, completion: completion)
        request.dialog.set(title: title)
        request.dialog.set(modal: true)
        if let acceptLabel {
            request.dialog.set(acceptLabel: acceptLabel)
        }
        if let initialName {
            request.dialog.initialName = initialName
        }
        if let mediaType {
            request.dialog.setDefault(filter: filter(for: mediaType))
        }
        request.start(parent: Gtk.WindowRef(parent))
    }

    private init(choice: Choice, cancellable: GIO.Cancellable?, completion: @escaping ([String]) -> Void) {
        self.choice = choice
        self.cancellable = cancellable
        self.completion = completion
    }

    private static func filter(for mediaType: String) -> FileFilter {
        let filter = FileFilter()
        filter.set(name: mediaType)
        filter.add(mimeType: mediaType)
        return filter
    }

    private func start(parent: Gtk.WindowRef) {
        let userData = Unmanaged.passRetained(self).toOpaque()
        let cancellableRef = cancellable.map { GIO.CancellableRef($0) }
        switch choice {
        case .saveAs:
            dialog.save(parent: parent, cancellable: cancellableRef, callback: fileDialogFinished, userData: userData)
        case .folder:
            dialog.selectFolder(parent: parent, cancellable: cancellableRef, callback: fileDialogFinished, userData: userData)
        case .files:
            dialog.openMultiple(parent: parent, cancellable: cancellableRef, callback: fileDialogFinished, userData: userData)
        case .folders:
            dialog.selectMultipleFolders(parent: parent, cancellable: cancellableRef, callback: fileDialogFinished, userData: userData)
        }
    }

    fileprivate func finish(_ result: GIO.AsyncResultRef) {
        completion(chosenPaths(from: result))
    }

    private func chosenPaths(from result: GIO.AsyncResultRef) -> [String] {
        do {
            switch choice {
            case .saveAs:
                return Self.paths(of: [try dialog.saveFinish(result: result)])
            case .folder:
                return Self.paths(of: [try dialog.selectFolderFinish(result: result)])
            case .files:
                return Self.paths(in: try dialog.openMultipleFinish(result: result))
            case .folders:
                return Self.paths(in: try dialog.selectMultipleFoldersFinish(result: result))
            }
        } catch {
            return []
        }
    }

    private static func paths(in files: GIO.ListModelRef) -> [String] {
        defer { g_object_unref(files.ptr) }
        let items = (0..<files.getNItems()).map { GIO.FileRef(raw: files.getItem(position: $0)!) }
        return paths(of: items)
    }

    private static func paths(of files: [GIO.FileRef]) -> [String] {
        defer { files.forEach { g_object_unref($0.ptr) } }
        return files.compactMap { $0.getPath() }
    }
}

private let fileDialogFinished: GAsyncReadyCallback = { _, result, userData in
    let resultAddress = UInt(bitPattern: result)
    let requestAddress = UInt(bitPattern: userData)
    MainActor.assumeIsolated {
        let request = Unmanaged<FileDialogRequest>.fromOpaque(UnsafeMutableRawPointer(bitPattern: requestAddress)!).takeRetainedValue()
        request.finish(GIO.AsyncResultRef(raw: UnsafeMutableRawPointer(bitPattern: resultAddress)!))
    }
}
