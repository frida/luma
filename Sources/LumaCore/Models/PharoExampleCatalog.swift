import Foundation

public struct PharoExample: Identifiable, Sendable {
    public var id: String { title }
    public let title: String
    public let code: String
}

public enum PharoExampleCatalog {
    public static let sections: [(heading: String, examples: [PharoExample])] = [
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
        ("Sound", [
            PharoExample(
                title: "Lead over bass \u{2014} two channels at once",
                code: """
                LumaSynth start.
                (LumaTune named: #lead channel: 0)
                    patch: #pulse; tempo: 132;
                    notes: #(0 4 7 4 0 4 7 11 7 4 0 - 0 4 7 -);
                    play.
                (LumaTune named: #bass channel: 1)
                    patch: #bass; tempo: 132; division: 2;
                    notes: #(c2 - c2 - as1 - g1 -);
                    play
                """),
            PharoExample(
                title: "Retune the lead while it loops",
                code: """
                "Run the two-channel example first, then run this. The loop
                 keeps time; the new notes land on the next bar."
                (LumaTune named: #lead)
                    scale: #(0 2 4 7 9);
                    notes: #(0 2 4 7 9 7 4 2 0 - 4 - 7 - 9 -);
                    tempo: 168
                """),
            PharoExample(
                title: "Noise percussion on its own channel",
                code: """
                LumaSynth start.
                (LumaTune named: #drums channel: 2)
                    patch: #noiseHit;
                    tempo: 132;
                    notes: #(c5 - - - c5 - c5 -);
                    play
                """),
            PharoExample(
                title: "Pickup blip \u{2014} a one-shot rising pair",
                code: """
                LumaSynth start.
                (LumaTune named: #sfx channel: 0)
                    patch: #pulse;
                    tempo: 300;
                    loops: false;
                    notes: #(b5 e6);
                    play
                """),
            PharoExample(
                title: "Jump \u{2014} a fast run reads as a sweep",
                code: """
                LumaSynth start.
                (LumaTune named: #sfx channel: 0)
                    patch: #pulse;
                    tempo: 420;
                    loops: false;
                    notes: #(c4 e4 g4 c5 e5 g5 c6);
                    play
                """),
            PharoExample(
                title: "Shape your own patch",
                code: """
                "Every field of a voice, as plain data. Channel 0, a hollow
                 detuned saw with a long resonant sweep."
                LumaSynth start.
                LumaSynth
                    channel: 0 waveform: LumaSynth saw detune: 0.12
                    attack: 0.01 decay: 0.5 sustain: 0 release: 0.1
                    cutoff: 1400 resonance: 0.7 gain: 0.6.
                (LumaTune named: #lead channel: 0) tempo: 96; notes: #(0 - 5 - 7 - 12 -); play
                """),
            PharoExample(
                title: "Silence everything",
                code: "LumaTune hush."),
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
