import SwiftUI

extension View {
    func unsavedChangesAlert(
        isPresented: Binding<Bool>,
        message: String,
        onSave: @escaping () -> Void,
        onDiscard: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) -> some View {
        alert("Unsaved Changes", isPresented: isPresented) {
            Button("Save") { onSave() }
            Button("Discard Changes", role: .destructive) { onDiscard() }
            Button("Cancel", role: .cancel) { onCancel() }
        } message: {
            Text(message)
        }
    }
}
