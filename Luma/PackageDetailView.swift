import SwiftUI

struct PackageDetailView: View {
    @Environment(\.modelContext) private var modelContext

    let package: InstalledPackage
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    @State private var isBusy = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    @State private var isLoadingFiles = false
    @State private var fileEntries: [PackageFileEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "shippingbox")
                    .font(.largeTitle)
                VStack(alignment: .leading) {
                    Text(package.name)
                        .font(.title)
                    Text("Installed version \(package.version)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button("Upgrade to Latest") {
                    upgrade()
                }
                .disabled(isBusy)

                Button(role: .destructive) {
                    remove()
                } label: {
                    Text("Remove Package")
                }
                .disabled(isBusy)
            }

            Divider()

            Text("Files")
                .font(.headline)

            Group {
                if isLoadingFiles {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading files…")
                            .foregroundStyle(.secondary)
                    }
                } else if fileEntries.isEmpty {
                    Text("No files found for this package.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(fileEntries) { entry in
                                HStack(spacing: 8) {
                                    Image(systemName: entry.isDirectory ? "folder" : "doc")
                                    Text(entry.relativePath)
                                        .font(.system(.footnote, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }

            Spacer()
        }
        .padding()
        .task(id: package.id) {
            await loadFiles()
        }
    }

    private func upgrade() {
        Task { @MainActor in
            isBusy = true
            statusMessage = "Checking for updates for \(package.name)…"
            errorMessage = nil

            let currentVersion = package.version

            defer { isBusy = false }

            do {
                let upgraded = try await workspace.upgradePackage(package)

                if upgraded.version == currentVersion {
                    statusMessage = "\(package.name) is already up to date."
                } else {
                    statusMessage = "Updated \(package.name) from \(currentVersion) to \(upgraded.version)."
                    selection = .package(upgraded.id)
                }
            } catch {
                errorMessage = "Failed to upgrade: \(error.localizedDescription)"
            }
        }
    }

    private func remove() {
        Task { @MainActor in
            isBusy = true
            statusMessage = "Removing \(package.name)…"
            errorMessage = nil

            let nextSelection = nextSidebarSelectionAfterRemovingCurrentPackage()

            defer { isBusy = false }

            do {
                try await workspace.removePackage(package)
                statusMessage = "Package removed."
                selection = nextSelection
            } catch {
                errorMessage = "Failed to remove: \(error.localizedDescription)"
            }
        }
    }

    @MainActor
    private func nextSidebarSelectionAfterRemovingCurrentPackage() -> SidebarItemID? {
        guard let projectPackages = try? workspace.projectPackagesState() else {
            return .notebook
        }

        let ordered = projectPackages.packages.sorted { $0.addedAt < $1.addedAt }

        guard !ordered.isEmpty else {
            return .notebook
        }

        if let idx = ordered.firstIndex(where: { $0.id == package.id }) {
            if idx > 0 {
                return .package(ordered[idx - 1].id)
            } else if ordered.count > 1 {
                return .package(ordered[1].id)
            } else {
                return .notebook
            }
        } else if let first = ordered.first {
            return .package(first.id)
        } else {
            return .notebook
        }
    }

    private func loadFiles() async {
        await MainActor.run {
            isLoadingFiles = true
        }

        do {
            let root = try await workspace.ensureCompilerWorkspaceReady()

            let fm = FileManager.default
            let packageRoot =
                root
                .appendingPathComponent("node_modules", isDirectory: true)
                .appendingPathComponent(package.name, isDirectory: true)

            guard fm.fileExists(atPath: packageRoot.path) else {
                await MainActor.run {
                    self.fileEntries = []
                    self.isLoadingFiles = false
                }
                return
            }

            let basePath = packageRoot.path
            var entries: [PackageFileEntry] = []

            if let enumerator = fm.enumerator(
                at: packageRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                while let url = enumerator.nextObject() as? URL {
                    guard url.path != basePath else { continue }

                    let rel: String
                    if url.path.hasPrefix(basePath + "/") {
                        rel = String(url.path.dropFirst(basePath.count + 1))
                    } else {
                        rel = url.lastPathComponent
                    }

                    let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey])
                    let isDir = resourceValues?.isDirectory ?? false

                    entries.append(PackageFileEntry(relativePath: rel, isDirectory: isDir))
                }
            }

            entries.sort {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }

            await MainActor.run {
                self.fileEntries = entries
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Failed to load files: \(error.localizedDescription)"
                self.fileEntries = []
            }
        }

        await MainActor.run {
            self.isLoadingFiles = false
        }
    }
}

private struct PackageFileEntry: Identifiable {
    let id = UUID()
    let relativePath: String
    let isDirectory: Bool
}
