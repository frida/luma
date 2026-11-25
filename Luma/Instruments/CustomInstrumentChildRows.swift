import LumaCore
import SwiftUI

struct CustomInstrumentChildRows: View {
    let sessionID: UUID
    let instance: LumaCore.InstrumentInstance
    let engine: Engine
    @Binding var selection: SidebarItemID?

    static let inlineLimit = 20

    var body: some View {
        let templates = engine.customInstruments.def(withId: UUID(uuidString: instance.sourceIdentifier)!)?.children ?? []
        let children = engine.children(of: instance.id)
        ForEach(templates) { template in
            let group = children.filter { $0.ref.template == template.id }
            if !group.isEmpty {
                if templates.count > 1 {
                    Text(template.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, sidebarGrandchildIndent)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(inline(group)) { child in
                    ChildRow(child: child, template: template)
                        .sidebarItemTag(SidebarItemID.instrumentChild(sessionID, instance.id, child.ref))
                }
                if group.count > Self.inlineLimit {
                    SidebarBrowseAllRow(count: group.count, title: "Show all \(group.count) \(template.name)\u{2026}") { dismiss in
                        browser(of: group, template: template, dismiss: dismiss)
                    }
                }
            }
        }
    }

    private func inline(_ group: [InstrumentChild]) -> [InstrumentChild] {
        let recent = Array(group.suffix(Self.inlineLimit))
        guard case .instrumentChild(_, let instanceID, let ref) = selection, instanceID == instance.id,
            !recent.contains(where: { $0.ref == ref }), let selected = group.first(where: { $0.ref == ref })
        else { return recent }
        return (recent + [selected]).sorted { $0.position < $1.position }
    }

    private func browser(of group: [InstrumentChild], template: InstrumentChildTemplate, dismiss: @escaping () -> Void) -> some View {
        SidebarBrowserPopover(
            placeholder: "Filter \(template.name.lowercased())",
            emptyMessage: "No matching \(template.name.lowercased())",
            items: group,
            groupName: { _ in template.name },
            title: { $0.title },
            help: { $0.subtitle ?? "" },
            isDimmed: { _ in false },
            matches: { child, query in
                child.title.localizedCaseInsensitiveContains(query)
                    || (child.subtitle ?? "").localizedCaseInsensitiveContains(query)
                    || (child.badge?.text ?? "").localizedCaseInsensitiveContains(query)
            },
            onChoose: { child in
                selection = .instrumentChild(sessionID, instance.id, child.ref)
                dismiss()
            }
        )
    }
}

private struct ChildRow: View {
    let child: InstrumentChild
    let template: InstrumentChildTemplate

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ChildTemplateIcon(template: template)
                .frame(width: sidebarChildIconWidth, alignment: .center)
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(child.title)
                        Spacer(minLength: 4)
                        badge
                    }
                    subtitle
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(child.title)
                        .truncationMode(.middle)
                    HStack(spacing: 4) {
                        badge
                        subtitle
                    }
                }
            }
            .lineLimit(1)
        }
        .font(.callout)
        .contentShape(Rectangle())
        .padding(.leading, sidebarGrandchildIndent)
        .help([child.title, child.subtitle].compactMap { $0 }.joined(separator: " \u{00B7} "))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var badge: some View {
        if let badge = child.badge {
            ChildBadgeView(text: badge.text, tone: badge.tone)
                .fixedSize()
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if let subtitle = child.subtitle {
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .truncationMode(.tail)
                .frame(idealWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }
}
