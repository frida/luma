import Frida
import LumaCore
import SwiftUI

enum TargetGrouping: Sendable {
    case flat
    case debuggableFirst(ApplicationDebuggability)
}

struct GroupedTargets<Target: DebuggableTarget, ID: Hashable, Row: View>: View {
    let targets: [Target]
    let id: KeyPath<Target, ID>
    let grouping: TargetGrouping
    @ViewBuilder let row: (Target) -> Row

    var body: some View {
        switch grouping {
        case .flat:
            rows(targets)
        case .debuggableFirst(let debuggability):
            let debuggable = targets.filter { $0.isDebuggable(per: debuggability) }
            let other = targets.filter { !$0.isDebuggable(per: debuggability) }

            if !debuggable.isEmpty {
                Section("Debuggable") {
                    rows(debuggable)
                }
            }

            if !other.isEmpty {
                Section("Other") {
                    rows(other)
                        .opacity(Self.dimmedOpacity)
                }
            }
        }
    }

    private func rows(_ members: [Target]) -> some View {
        ForEach(members, id: id, content: row)
    }

    private static var dimmedOpacity: Double { 0.5 }
}

protocol DebuggableTarget {
    func isDebuggable(per debuggability: ApplicationDebuggability) -> Bool
}

extension ApplicationDetails: DebuggableTarget {
    func isDebuggable(per debuggability: ApplicationDebuggability) -> Bool {
        debuggability.isDebuggable(self)
    }
}

extension ProcessDetails: DebuggableTarget {
    func isDebuggable(per debuggability: ApplicationDebuggability) -> Bool {
        debuggability.isDebuggable(self)
    }
}
