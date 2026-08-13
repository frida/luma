import Foundation

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
                | graph |
                graph := Mondrian new.
                graph nodes with: (1 to: 8).
                graph edges connectTo: [ :n | (n rem: 8) + 1 ].
                graph layout circle.
                graph
                """),
            PharoExample(
                title: "Graph — a class tree",
                code: """
                | graph |
                graph := Mondrian new.
                graph nodes with: Number withAllSubclasses.
                graph edges connectFrom: [ :aClass | aClass superclass ].
                graph layout horizontalTree.
                graph
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
            PharoExample(
                title: "Line chart",
                code: """
                GtPlotterLineChart new
                	with: (GtPlotterDataGroup new values: (1 to: 12));
                	valueX: [ :n | n ];
                	valueY: [ :n | n * n ];
                	yourself.
                """),
            PharoExample(
                title: "Scatter plot",
                code: """
                GtPlotterScatterChart new
                	with: (GtPlotterDataGroup new values: (1 to: 30));
                	valueX: [ :n | n ];
                	valueY: [ :n | (n rem: 7) + n // 3 ];
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
