import Foundation

extension Process {
    /// A guest keeps its disk image locked for as long as it lives, so the
    /// next boot has to wait for this one to be gone rather than merely asked
    /// to leave.
    func terminateAndWaitForExit() async {
        terminate()

        let deadline = Date().addingTimeInterval(Self.gracefulExitSeconds)
        while isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        guard isRunning else { return }

        #if !os(Windows)
        kill(processIdentifier, SIGKILL)
        #endif
        while isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private static let gracefulExitSeconds: TimeInterval = 5
}
