import Foundation
import QuartzCore

nonisolated final class DisplayLinkThread: @unchecked Sendable {
    private let link: CADisplayLink
    private let thread: Thread
    private let runLoop: CFRunLoop

    init(link: CADisplayLink, name: String) {
        link.isPaused = true
        nonisolated(unsafe) let unsafeLink = link
        nonisolated(unsafe) var startedRunLoop: CFRunLoop?
        let started = DispatchSemaphore(value: 0)
        let thread = Thread {
            startedRunLoop = CFRunLoopGetCurrent()
            unsafeLink.add(to: .current, forMode: .common)
            started.signal()
            while !Thread.current.isCancelled {
                CFRunLoopRun()
            }
            unsafeLink.invalidate()
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
        self.link = link
        self.thread = thread
        runLoop = startedRunLoop!
    }

    func setPaused(_ paused: Bool) {
        perform { link in link.isPaused = paused }
    }

    func stop() {
        thread.cancel()
        perform { _ in CFRunLoopStop(CFRunLoopGetCurrent()) }
    }

    private func perform(_ change: @escaping (CADisplayLink) -> Void) {
        nonisolated(unsafe) let link = self.link
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { change(link) }
        CFRunLoopWakeUp(runLoop)
    }
}
