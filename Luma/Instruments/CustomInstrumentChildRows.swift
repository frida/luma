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
            ChildRowText(title: child.title, subtitle: child.subtitle, badge: child.badge.map { ($0.text, $0.tone) })
        }
        .font(.callout)
        .contentShape(Rectangle())
        .padding(.leading, sidebarGrandchildIndent)
        .help([child.title, child.subtitle].compactMap { $0 }.joined(separator: " \u{00B7} "))
        .accessibilityElement(children: .combine)
    }
}

struct ChildRowText: View {
    let title: String
    let subtitle: String?
    let badge: (text: String, tone: ChildBadge.Tone)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TitleAndBadge {
                Text(title)
                    .truncationMode(.middle)
                badgeView
            }
            subtitleView
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private var badgeView: some View {
        if let badge {
            ChildBadgeView(text: badge.text, tone: badge.tone, truncates: true)
        }
    }

    @ViewBuilder
    private var subtitleView: some View {
        if let subtitle {
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .truncationMode(.tail)
        }
    }
}

private struct TitleAndBadge: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let idealWidth = ideal.map(\.width).reduce(0, +) + Self.spacing * CGFloat(subviews.count - 1)
        return CGSize(width: proposal.width ?? idealWidth, height: ideal.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let title = subviews[0]
        guard subviews.count > 1 else {
            title.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: bounds.width, height: nil))
            return
        }
        let badge = subviews[1]
        let badgeMinimum = badge.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width
        let titleWidth = min(title.sizeThatFits(.unspecified).width, max(0, bounds.width - badgeMinimum - Self.spacing))
        let badgeWidth = min(badge.sizeThatFits(.unspecified).width, max(badgeMinimum, bounds.width - titleWidth - Self.spacing))
        title.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: titleWidth, height: nil))
        badge.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(width: badgeWidth, height: nil))
    }

    private static let spacing: CGFloat = 8
}
