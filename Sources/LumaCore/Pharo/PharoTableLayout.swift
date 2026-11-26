import Foundation
import SwiftyPharo

public struct PharoTableLayout {
    public struct Metrics {
        public let measure: (String) -> Double
        public let characterWidth: Double
        public let iconWidth: Double
        public let padding: Double
        public let spacing: Double

        public init(measure: @escaping (String) -> Double, iconWidth: Double, padding: Double, spacing: Double) {
            self.measure = measure
            self.characterWidth = measure("0")
            self.iconWidth = iconWidth
            self.padding = padding
            self.spacing = spacing
        }
    }

    public enum Fit: String, Sendable {
        case whole
        case truncated
        case dropped
    }

    public static let flexibleMinimumCharacters = 6
    public static let fittedMaximumCharacters = 48

    public let columns: [PharoColumn]
    private let content: [Double]
    private let metrics: Metrics

    public static func isDeclared(_ columns: [PharoColumn]) -> Bool {
        columns.contains(where: \.isDeclared)
    }

    public init(columns: [PharoColumn], rows: [[PharoCell]], total: Int, metrics: Metrics) {
        self.columns = columns
        self.metrics = metrics
        content = columns.indices.map { column in
            let cells = column == 0
                ? [metrics.measure(String(repeating: "0", count: max(String(total).count, 3)))]
                : rows.map { Self.width(of: $0[column], metrics: metrics) }
            return cells.reduce(metrics.measure(columns[column].title), max)
        }
    }

    public func widths(in available: Double) -> [Double?] {
        let plans = columns.indices.map(plan(of:))
        let order = givingWayOrder
        let kept = order.last.map(priority(of:))
        var shown = Set(columns.indices)
        var squeezed: Set<Int> = []
        for column in order {
            if required(plans, shown, squeezed) <= available { break }
            squeezed.insert(column)
            if required(plans, shown, squeezed) <= available { break }
            if priority(of: column) != kept {
                shown.remove(column)
            }
        }
        let widths = distribute(available - required(plans, shown, squeezed), plans, shown, squeezed)
        return columns.indices.map { shown.contains($0) ? widths[$0] : nil }
    }

    public func isFlexible(_ column: Int) -> Bool {
        plan(of: column).weight != nil
    }

    public func minimumWidth(of column: Int) -> Double {
        plan(of: column).minimum
    }

    public func fit(of column: Int, width: Double?) -> Fit {
        guard let width else { return .dropped }
        return width + 0.5 >= content[column] + metrics.padding ? .whole : .truncated
    }

    private struct Plan {
        let want: Double
        let minimum: Double
        let weight: Double?
    }

    private static func width(of cell: PharoCell, metrics: Metrics) -> Double {
        cell.png != nil ? metrics.iconWidth : metrics.measure(cell.text ?? "")
    }

    private func plan(of column: Int) -> Plan {
        let padding = metrics.padding
        let declared = columns[column]
        let minimum = declared.minimumCharacters.map { characters(Double($0)) + padding }
        if column == 0 {
            return Plan(want: content[column] + padding, minimum: content[column] + padding, weight: nil)
        }
        switch declared.width {
        case .fitContent:
            let want = min(content[column], characters(Double(Self.fittedMaximumCharacters))) + padding
            return Plan(want: want, minimum: min(minimum ?? want, want), weight: nil)
        case .points(let points):
            return Plan(want: points, minimum: min(minimum ?? points, points), weight: nil)
        case .weight(let weight):
            return flexible(weight: weight, minimum: minimum)
        case nil:
            return flexible(weight: 1, minimum: minimum)
        }
    }

    private func characters(_ count: Double) -> Double {
        count * metrics.characterWidth
    }

    private func flexible(weight: Double, minimum: Double?) -> Plan {
        let least = minimum ?? characters(Double(Self.flexibleMinimumCharacters)) + metrics.padding
        return Plan(want: least, minimum: least, weight: weight)
    }

    private var givingWayOrder: [Int] {
        columns.indices.dropFirst().sorted { a, b in
            priority(of: a) != priority(of: b) ? priority(of: a) > priority(of: b) : a > b
        }
    }

    private func priority(of column: Int) -> Double {
        columns[column].priority ?? .infinity
    }

    private func required(_ plans: [Plan], _ shown: Set<Int>, _ squeezed: Set<Int>) -> Double {
        shown.reduce(0) { sum, column in
            sum + (squeezed.contains(column) ? plans[column].minimum : plans[column].want) + metrics.spacing
        }
    }

    private func distribute(_ slack: Double, _ plans: [Plan], _ shown: Set<Int>, _ squeezed: Set<Int>) -> [Double] {
        var widths = plans.indices.map { squeezed.contains($0) ? plans[$0].minimum : plans[$0].want }
        let last = shown.max()!
        guard slack >= 0 else {
            widths[last] = max(widths[last] + slack, 0)
            return widths
        }
        var left = slack
        for column in givingWayOrder.reversed() where shown.contains(column) && squeezed.contains(column) {
            let grown = min(left, plans[column].want - widths[column])
            widths[column] += grown
            left -= grown
        }
        let flexible = shown.filter { plans[$0].weight != nil }
        guard !flexible.isEmpty else {
            widths[last] += left
            return widths
        }
        let total = flexible.reduce(left) { $0 + widths[$1] }
        for (column, width) in shares(of: total, among: flexible, plans) {
            widths[column] = width
        }
        return widths
    }

    private func shares(of total: Double, among flexible: Set<Int>, _ plans: [Plan]) -> [Int: Double] {
        var sharing = flexible
        var remaining = total
        var shares: [Int: Double] = [:]
        while !sharing.isEmpty {
            let weights = sharing.reduce(0) { $0 + plans[$1].weight! }
            let starved = sharing.filter { remaining * plans[$0].weight! / weights < plans[$0].minimum }
            guard !starved.isEmpty else {
                for column in sharing {
                    shares[column] = remaining * plans[column].weight! / weights
                }
                return shares
            }
            for column in starved {
                shares[column] = plans[column].minimum
                remaining -= plans[column].minimum
            }
            sharing.subtract(starved)
        }
        return shares
    }
}
