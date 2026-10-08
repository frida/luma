import LumaCore
import SwiftUI

struct ThreadSidebarChildren: View {
    let sessionID: UUID
    let engine: Engine
    @Binding var selection: SidebarItemID?

    var body: some View {
        let threads = engine.session(id: sessionID)?.lastKnownThreads ?? []
        let highlights = threads.sidebarHighlights(selectedID: selectedThreadID)
        ForEach(highlights) { thread in
            ThreadSidebarRow(sessionID: sessionID, thread: thread, engine: engine, selection: $selection)
                .sidebarItemTag(SidebarItemID.thread(sessionID, thread.id))
        }
        if threads.count > highlights.count {
            SidebarBrowseAllRow(count: threads.count) { dismiss in
                ThreadBrowserPopover(
                    sessionID: sessionID,
                    threads: threads,
                    selection: $selection,
                    onDismiss: dismiss
                )
            }
        }
    }

    private var selectedThreadID: ProcessThread.ID? {
        if case .thread(let sid, let tid) = selection, sid == sessionID { return tid }
        return engine.lastSelectedThreadID(for: sessionID)
    }
}

private struct ThreadSidebarRow: View {
    let sessionID: UUID
    let thread: ProcessThread
    let engine: Engine
    @Binding var selection: SidebarItemID?

    var body: some View {
        SidebarFeatureRowLabel(
            icon: { Image(systemName: "cpu").font(.system(size: 11)) },
            title: thread.name ?? "tid \(thread.id)",
            help: "tid \(thread.id)"
        )
        .contextMenu {
            let actions = engine.threadActions(sessionID: sessionID, thread: thread)
            ForEach(actions) { action in
                Button(role: action.role == .destructive ? .destructive : nil) {
                    Task { @MainActor in
                        if let target = await action.perform() {
                            selection = SidebarItemID(navigationTarget: target)
                        }
                    }
                } label: {
                    if let icon = action.systemImage {
                        Label(action.title, systemImage: icon)
                    } else {
                        Text(action.title)
                    }
                }
            }
        }
    }
}

struct ThreadBrowserPopover: View {
    let sessionID: UUID
    let threads: [ProcessThread]
    @Binding var selection: SidebarItemID?
    let onDismiss: () -> Void

    var body: some View {
        SidebarBrowserPopover(
            placeholder: "Filter threads",
            emptyMessage: "No matching threads",
            items: threads,
            groupName: { $0.name == nil ? "Unnamed" : "Named" },
            title: { $0.name ?? "tid \($0.id)" },
            help: { "tid \($0.id)" },
            isDimmed: { _ in false },
            matches: { thread, query in
                (thread.name?.localizedCaseInsensitiveContains(query) ?? false)
                    || String(thread.id).localizedCaseInsensitiveContains(query)
            },
            onChoose: { thread in
                selection = .thread(sessionID, thread.id)
                onDismiss()
            }
        )
    }
}
