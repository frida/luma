import SwiftUI

struct SaveBarOverlay: View {
    let isDirty: Bool
    var showSavedCheck: Bool = false
    var saveTooltip: String = "Save"
    let onSave: () -> Void

    private var visible: Bool { isDirty || showSavedCheck }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if visible {
                bar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            shortcutHost
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(visible)
        .animation(.easeInOut(duration: 0.2), value: visible)
    }

    private var bar: some View {
        HStack(spacing: 8) {
            if showSavedCheck {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.medium))
            } else {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                Text("Unsaved")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Save", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help(saveTooltip)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .clipShape(
            UnevenRoundedRectangle(
                bottomLeadingRadius: 8,
                bottomTrailingRadius: 8
            )
        )
        .overlay(
            UnevenRoundedRectangle(
                bottomLeadingRadius: 8,
                bottomTrailingRadius: 8
            )
            .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
        .padding(.trailing, 16)
        .background(CursorOverrideRegion())
    }

    private var shortcutHost: some View {
        Button("", action: onSave)
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(!isDirty)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}
