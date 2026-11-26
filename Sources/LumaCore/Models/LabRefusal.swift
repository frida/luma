import Foundation

enum LabRefusal {
    static func sentence(_ reason: String) -> String {
        let said = withoutOpKind(reason)
        if said.hasPrefix("invalid '") && said.hasSuffix("' op") {
            return "the lab could not read it"
        }
        if said.hasPrefix("invalid '") && said.hasSuffix("'") {
            return "the lab does not take its \(said.dropFirst("invalid '".count).dropLast())"
        }
        return clauses[said] ?? said
    }

    private static func withoutOpKind(_ reason: String) -> String {
        guard let colon = reason.range(of: ": "),
            reason[..<colon.lowerBound].allSatisfy({ $0.isLowercase || $0 == "_" || $0 == "-" })
        else { return reason }
        return String(reason[colon.upperBound...])
    }

    private static let clauses = [
        "too many files": "it holds more files than the lab takes",
        "too many widgets": "it has more widgets than the lab takes",
        "too many settings": "it has more settings than the lab takes",
        "too many dependencies": "it has more dependencies than the lab takes",
        "too many child templates": "it has more kinds of children than the lab takes",
        "too many patterns": "the lab already holds as many patterns as it takes",
        "unknown session": "the lab does not have its session",
        "the lab does not have this instrument's definition": "the lab does not have the instrument it is an instance of",
        "invalid name": "its name is not one the lab takes",
        "invalid child template": "one of its kinds of children is not one the lab takes",
    ]
}
