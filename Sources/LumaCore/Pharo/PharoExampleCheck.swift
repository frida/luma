import Foundation
import SwiftyPharo

/// Reads every example in the catalogue the way the image would, and says
/// what it could not make sense of. The examples are Smalltalk in Swift string
/// literals, which nothing else looks at: three of them have shipped broken.
public enum PharoExampleCheck {
    /// Answers a line per complaint, and nothing at all when the catalogue is
    /// sound.
    public static func run(in runtime: PharoRuntime) async throws -> [String] {
        let report = try await runtime.evaluate(source)
        return report.printString
            .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Parsing rather than running: what a snippet does needs a host, a synth
    /// and a scene, but what it says can be read on its own.
    private static var source: String {
        """
        | sources titles implemented assigned report |
        sources := { \(literals(of: \.code)) }.
        titles := { \(literals(of: \.title)) }.

        implemented := IdentitySet new.
        Smalltalk allClasses do: [ :each |
            implemented addAll: each selectors; addAll: each class selectors ].

        "A name anything assigns anywhere counts as known: the examples build
         on each other, and are meant to be run in turn."
        assigned := Set new.
        sources do: [ :each |
            [ (RBParser parseExpression: each) nodesDo: [ :node |
                node isAssignment ifTrue: [ assigned add: node variable name asString ] ] ]
                on: Error do: [ :ignored | ] ].

        report := OrderedCollection new.
        sources doWithIndex: [ :each :index |
            | ast named |
            ast := [ RBParser parseExpression: each ]
                on: Error
                do: [ :error |
                    report add: (titles at: index) , ': syntax: ' , error messageText.
                    nil ].
            ast ifNotNil: [
                named := Set withAll: #('self' 'super' 'true' 'false' 'nil' 'thisContext').
                ast nodesDo: [ :node |
                    node isSequence ifTrue: [
                        named addAll: (node temporaryNames collect: [ :temp | temp asString ]) ].
                    node isBlock ifTrue: [
                        named addAll: (node argumentNames collect: [ :arg | arg asString ]) ] ].
                ast nodesDo: [ :node |
                    node isMessage ifTrue: [
                        (implemented includes: node selector) ifFalse: [
                            report add: (titles at: index) , ': no such message #' , node selector ] ].
                    node isVariable ifTrue: [
                        | name |
                        name := node name asString.
                        (name first isUppercase
                            ifTrue: [ Smalltalk includesKey: name asSymbol ]
                            ifFalse: [ (assigned includes: name) or: [ named includes: name ] ])
                                ifFalse: [
                                    report add: (titles at: index) , ': nothing named ' , name ] ] ] ] ].
        String lf join: report
        """
    }

    /// The catalogue as a Smalltalk literal array, with its quotes doubled.
    private static func literals(of field: KeyPath<PharoExample, String>) -> String {
        PharoExampleCatalog.sections
            .flatMap(\.examples)
            .map { "'" + $0[keyPath: field].replacingOccurrences(of: "'", with: "''") + "'" }
            .joined(separator: ". ")
    }
}
