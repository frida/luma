#if os(macOS)

    import Combine
    import Sparkle
    import SwiftUI

    @MainActor
    final class LumaUpdater: ObservableObject {
        let controller: SPUStandardUpdaterController
        @Published var canCheckForUpdates = false

        init() {
            controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )

            #if DEBUG
                controller.updater.automaticallyChecksForUpdates = false
            #endif

            controller.updater.publisher(for: \.canCheckForUpdates)
                .receive(on: RunLoop.main)
                .assign(to: &$canCheckForUpdates)
        }

        func checkForUpdates() {
            controller.checkForUpdates(nil)
        }
    }

    struct CheckForUpdatesView: View {
        @ObservedObject var updater: LumaUpdater

        var body: some View {
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }
    }

#endif
