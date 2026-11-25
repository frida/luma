import LumaCore
import SwiftUI

struct InstrumentChildPage: View {
    let instanceID: UUID
    let sessionID: UUID
    let child: ChildRef
    let engine: Engine
    @Binding var selection: SidebarItemID?

    var body: some View {
        Group {
            if let instance, let current, let template = engine.childTemplate(child.template, of: instance), let def {
                InstrumentWidgetPage(
                    widgets: template.widgets,
                    layout: template.pageLayout,
                    child: current,
                    gate: InstrumentPageGate(instanceID: instance.id, icon: def.icon, name: def.name),
                    engine: engine,
                    selection: $selection
                ) {
                    InstrumentChildHeader(child: current, template: template, status: status)
                }
                .environment(\.instrumentSession, engine.sessions.first { $0.id == sessionID })
                .environment(\.instrumentInstance, instance)
            }
        }
        .frame(minWidth: 360, minHeight: 300)
        .onChange(of: current == nil, initial: true) { _, isGone in
            if isGone {
                selection = .instrument(sessionID, instanceID)
            }
        }
    }

    private var instance: LumaCore.InstrumentInstance? {
        engine.instrumentsBySession[sessionID]?.first { $0.id == instanceID }
    }

    private var current: InstrumentChild? {
        engine.children(of: instanceID).first { $0.ref == child }
    }

    private var def: CustomInstrumentDef? {
        instance.flatMap { UUID(uuidString: $0.sourceIdentifier) }.flatMap(engine.customInstruments.def(withId:))
    }

    private var status: InstrumentStatus? {
        engine.node(forSessionID: sessionID)?.instruments.first { $0.id == instanceID }?.status
    }
}

private struct InstrumentChildHeader: View {
    let child: InstrumentChild
    let template: InstrumentChildTemplate
    let status: InstrumentStatus?

    var body: some View {
        HStack(spacing: 8) {
            ChildTemplateIcon(template: template)
            Text(child.title)
                .font(.headline)
            if let subtitle = child.subtitle {
                Text("\u{00B7}")
                    .foregroundStyle(.secondary)
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            if let badge = child.badge {
                ChildBadgeView(text: badge.text, tone: badge.tone)
            }
            if let status {
                InstrumentStatusIndicator(status: status)
            }
            Spacer()
        }
        .lineLimit(1)
    }
}

struct ChildTemplateIcon: View {
    let template: InstrumentChildTemplate

    var body: some View {
        InstrumentIconView(icon: .symbolic(template.symbol ?? InstrumentIconCatalog.default.id), pointSize: 12)
    }
}

struct ChildBadgeView: View {
    let text: String
    let tone: ChildBadge.Tone

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tone.color.opacity(0.18), in: Capsule())
            .foregroundStyle(tone.color)
            .accessibilityLabel(text)
    }
}

extension ChildBadge.Tone {
    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .ended: return .secondary.opacity(0.6)
        case .active: return .green
        case .waiting: return .orange
        case .failed: return .red
        }
    }
}
