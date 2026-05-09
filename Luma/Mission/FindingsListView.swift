import LumaCore
import SwiftUI

struct FindingsListView: View {
    @ObservedObject var workspace: Workspace
    let missionID: UUID
    let findings: [MissionFinding]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "checkmark.seal")
                Text("Findings").font(.headline)
                Spacer()
                Text("\(findings.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding()

            if findings.isEmpty {
                Text("None recorded yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(findings) { finding in
                            FindingCard(workspace: workspace, finding: finding)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct FindingCard: View {
    @ObservedObject var workspace: Workspace
    let finding: MissionFinding

    @State private var evidence: [MissionEvidence] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(finding.title).font(.body.weight(.semibold))
                Spacer()
                ConfidencePill(confidence: finding.confidence)
            }
            Text(finding.bodyMarkdown).font(.callout).textSelection(.enabled)

            if !evidence.isEmpty {
                DisclosureGroup("\(evidence.count) evidence") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(evidence) { ev in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: iconForKind(ev.kind))
                                    .foregroundStyle(.tint)
                                Text(ev.refJSON).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                }
            }

            HStack {
                StatusPill(status: finding.status)
                Spacer()
                if finding.status == .accepted {
                    Button {
                        addFindingToNotebook()
                    } label: {
                        Label("Add to Notebook", systemImage: "book.pages")
                    }
                }
                if finding.status == .proposed {
                    Button("Refute") { workspace.engine.refuteFinding(findingID: finding.id) }
                    Button("Accept") { workspace.engine.acceptFinding(findingID: finding.id) }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: finding.id) {
            evidence = (try? workspace.store.fetchMissionEvidence(findingID: finding.id)) ?? []
        }
    }

    private func addFindingToNotebook() {
        let processName = finding.sessionID.flatMap { sid in
            workspace.engine.sessions.first(where: { $0.id == sid })?.processName
        }
        let entry = NotebookEntry(
            kind: .note,
            title: finding.title,
            details: finding.bodyMarkdown,
            sessionID: finding.sessionID,
            processName: processName
        )
        workspace.engine.addNotebookEntry(entry)
    }

    private func iconForKind(_ kind: MissionEvidenceKind) -> String {
        switch kind {
        case .event: return "dot.radiowaves.left.and.right"
        case .hookHit: return "scope"
        case .disasmSpan: return "list.dash"
        case .memoryRead: return "memorychip"
        case .symbolMatch: return "function"
        case .insight: return "magnifyingglass.circle"
        case .action: return "wrench.adjustable"
        }
    }
}

private struct ConfidencePill: View {
    let confidence: MissionFindingConfidence

    var body: some View {
        Text(confidence.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch confidence {
        case .low: .gray
        case .medium: .orange
        case .high: .green
        }
    }
}

private struct StatusPill: View {
    let status: MissionFindingStatus

    var body: some View {
        Text(status.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .proposed: .orange
        case .accepted: .green
        case .refuted: .red
        case .superseded: .gray
        }
    }
}
