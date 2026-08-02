import Foundation

/// Snippets the examples button drops into a page, each one exercising a feature
/// so a reader can discover it by running it. Several carry a hint in their title
/// about a key to press once the result is up.
struct PharoExample: Identifiable {
    var id: String { title }
    let title: String
    let code: String
}

enum PharoExampleCatalog {
    static let sections: [(heading: String, examples: [PharoExample])] = [
        ("Visualize", [
            PharoExample(
                title: "Graph — a ring",
                code: """
                Mondrian new
                	nodes with: (1 to: 8);
                	edges connectTo: [ :n | (n rem: 8) + 1 ];
                	layout circle.
                """),
            PharoExample(
                title: "Graph — a class tree",
                code: """
                Mondrian new
                	nodes with: Number withAllSubclasses;
                	edges connectFrom: [ :aClass | aClass superclass ];
                	layout horizontalTree.
                """),
            PharoExample(
                title: "Bar chart",
                code: """
                GtPlotter new horizontalBarChart
                	barWidthData: [ :each | each ];
                	with: (GtPlotterDataGroup new
                			 values: #( 3 7 5 9 2 6 );
                			 labelled: [ :each | 'item ' , each printString ];
                			 yourself);
                	yourself.
                """),
        ]),
        ("Explore", [
            PharoExample(
                title: "Filter a big list (type in the field)",
                code: "Smalltalk globals keys asSortedCollection asArray."),
            PharoExample(
                title: "Browse — put the cursor on a message, press \u{2318}M / \u{2318}N",
                code: "OrderedCollection new addAll: #( 1 2 3 ); yourself."),
            PharoExample(
                title: "Format — messy code, press \u{2318}\u{21E7}F",
                code: "x:=1+2*3.  y:=x factorial.   { x. y }."),
        ]),
        ("Basics", [
            PharoExample(
                title: "A collection to inspect",
                code: "1 to: 100."),
            PharoExample(
                title: "A shared variable",
                code: "total := (1 to: 10) inject: 0 into: [ :a :b | a + b ]."),
        ]),
    ]
}
