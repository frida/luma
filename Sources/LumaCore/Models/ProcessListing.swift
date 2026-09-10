import Foundation
import Frida

extension Sequence where Element == ProcessDetails {
    public func sortedWithKernelFirst() -> [ProcessDetails] {
        sorted { lhs, rhs in
            if (lhs.pid == 0) != (rhs.pid == 0) { return lhs.pid == 0 }

            let lhsHasIcon = !lhs.icons.isEmpty
            let rhsHasIcon = !rhs.icons.isEmpty
            if lhsHasIcon != rhsHasIcon { return lhsHasIcon }

            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
