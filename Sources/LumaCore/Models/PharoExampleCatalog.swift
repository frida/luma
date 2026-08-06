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
        ("Draw", [
            PharoExample(
                title: "A scene of your own, among an object's views",
                code: """
                "The scene is the host's; the image keeps its handle and says
                 which one to draw. Inspect the answer to find the Scene tab.
                 shape stays put for the two snippets that change it."
                scene := LumaCanvas new.
                shape := scene addDrawable.
                shape
                    attribute: 'p' components: 3;
                    varying: 'vc' components: 3;
                    uniform: 'tint' value: #(1 0.4 0.2);
                    vertexSource: 'void main() {
                        vc = vec3(0.5) + p * 0.5;
                        gl_Position = u_mvp * vec4(p, 1.0); }'
                    fragmentSource: 'void main() { frag_color = vec4(vc * tint, 1.0); }';
                    identity;
                    mesh: #(-0.8 -0.6 0   0.8 -0.6 0   0 0.8 0) primitive: #triangles.
                scene
                """),
            PharoExample(
                title: "Say what a value should do, and leave it to draw",
                code: """
                "Run the scene example first. Nothing here runs per frame: the
                 shape is told the shape of the change, and whichever renderer
                 draws it works the value out on its own clock."
                shape oscillate: 'tint' between: #(1 0.4 0.2) and: #(0.2 0.4 1) period: 3
                """),
            PharoExample(
                title: "Picture a run of values too large for a uniform",
                code: """
                "A buffer is read by index through <name>At, held as a texture,
                 so handing over a fresh window is all a scrub costs."
                profileScene := LumaCanvas new.
                profile := profileScene addDrawable.
                profile
                    attribute: 'p' components: 2;
                    varying: 'uv' components: 2;
                    buffer: 'samples' values: ((0 to: 255) collect: [ :i | (i / 40.0) sin abs ]);
                    vertexSource: 'void main() {
                        uv = p * 0.5 + 0.5;
                        gl_Position = vec4(p, 0.0, 1.0); }'
                    fragmentSource: 'void main() {
                        float v = samplesAt(int(uv.x * 255.0));
                        frag_color = vec4(uv.y < v ? vec3(0.2, 0.9, 0.5) : vec3(0.09), 1.0); }';
                    mesh: #(-1 -1  1 -1  -1 1   1 -1  1 1  -1 1) primitive: #triangles.
                profileScene
                """),
            PharoExample(
                title: "Hide a drawable, and bring it back",
                code: """
                "A scene is kept, not rebuilt: changing one part leaves the
                 rest, and its shaders, alone."
                shape hide.
                "then, separately:  shape show"
                """),
            PharoExample(
                title: "Your sessions, as icons on turning cards",
                code: """
                "A picture is any Form, so what the host already carries -- a
                 session's icon -- goes straight onto a card of its own."
                iconScene := LumaCanvas new.
                shown := LumaProject sessions items select: [ :each | each icon notNil ].
                shown doWithIndex: [ :session :index |
                    | angle card |
                    angle := 2 * Float pi * (index - 1) / shown size.
                    card := iconScene addDrawable.
                    card
                        attribute: 'p' components: 2;
                        varying: 'uv' components: 2;
                        uniform: 'centre' value: { angle sin * 0.55. angle cos * 0.55 };
                        image: 'icon' form: session icon;
                        vertexSource: 'void main() {
                            uv = vec2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
                            vec2 square = vec2(min(u_resolution.y / u_resolution.x, 1.0),
                                               min(u_resolution.x / u_resolution.y, 1.0));
                            gl_Position = u_mvp * vec4((p * 0.2 + centre) * square, 0.0, 1.0); }'
                        fragmentSource: 'void main() {
                            vec4 c = texture(icon, uv);
                            if (c.a < 0.01) discard;
                            frag_color = vec4(c.rgb * c.a, c.a); }';
                        mesh: #(-1 -1  1 -1  -1 1   1 -1  1 1  -1 1) primitive: #triangles;
                        oscillate: 'centre'
                            between: { angle sin * 0.55. angle cos * 0.55 }
                            and: { angle sin * 0.7. angle cos * 0.7 }
                            period: 4 ].
                iconScene
                """),
            PharoExample(
                title: "Icons on parade, with a tune under them",
                code: """
                "Three channels and a ring of cards, started together. Hush
                 with: LumaTune hush"
                LumaSynth start.
                (LumaTune named: #lead channel: 0)
                    patch: #pulse; tempo: 150;
                    notes: #(c5 e5 g5 e5 a5 g5 e5 c5 d5 f5 a5 f5 g5 e5 c5 -);
                    play.
                (LumaTune named: #bass channel: 1)
                    patch: #bass; tempo: 150; division: 2;
                    notes: #(c2 - g2 - a2 - f2 -);
                    play.
                (LumaTune named: #drums channel: 2)
                    patch: #noiseHit; tempo: 150;
                    notes: #(c5 - c5 c5 - c5 c5 -);
                    play.

                parade := LumaCanvas new.
                shown := LumaProject sessions items select: [ :each | each icon notNil ].
                shown doWithIndex: [ :session :index |
                    | angle card |
                    angle := 2 * Float pi * (index - 1) / shown size.
                    card := parade addDrawable.
                    card
                        attribute: 'p' components: 2;
                        varying: 'uv' components: 2;
                        uniform: 'centre' value: { angle sin * 0.55. angle cos * 0.55 };
                        image: 'icon' form: session icon;
                        vertexSource: 'void main() {
                            uv = vec2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
                            vec2 square = vec2(min(u_resolution.y / u_resolution.x, 1.0),
                                               min(u_resolution.x / u_resolution.y, 1.0));
                            float beat = 1.0 + 0.12 * sin(u_time * 5.0);
                            gl_Position = vec4((p * 0.2 * beat + centre) * square, 0.0, 1.0); }'
                        fragmentSource: 'void main() {
                            vec4 c = texture(icon, uv);
                            if (c.a < 0.01) discard;
                            frag_color = vec4(c.rgb * c.a, c.a); }';
                        mesh: #(-1 -1  1 -1  -1 1   1 -1  1 1  -1 1) primitive: #triangles;
                        oscillate: 'centre'
                            between: { angle sin * 0.5. angle cos * 0.5 }
                            and: { angle sin * 0.72. angle cos * 0.72 }
                            period: 3.2 ].
                parade
                """),
            PharoExample(
                title: "Catch \u{2014} a game of pointer, keys and blips",
                code: """
                "Inspect the answer, click the Scene tab to give it the keys,
                 then move the paddle with the pointer or the arrow keys.
                 Escape ends it, as does: playing terminate"
                LumaSynth start.
                game := LumaCanvas new.
                icons := (LumaProject sessions items
                    select: [ :each | each icon notNil ]
                    thenCollect: [ :each | each icon ])
                        ifEmpty: [ { (Form extent: 64 @ 64 depth: 32)
                            fillColor: Color magenta; yourself } ].

                square := 'vec2 square = vec2(min(u_resolution.y / u_resolution.x, 1.0),
                                              min(u_resolution.x / u_resolution.y, 1.0));'.
                paddle := game addDrawable.
                paddle
                    attribute: 'p' components: 2;
                    uniform: 'at' value: #(0 -0.8);
                    uniform: 'warmth' value: 0;
                    vertexSource: 'void main() { ', square, '
                        gl_Position = vec4((p * vec2(0.22, 0.04) + at) * square, 0.0, 1.0); }'
                    fragmentSource: 'void main() {
                        frag_color = vec4(0.15 + warmth, 0.85 - warmth * 0.5, 0.55, 1.0); }';
                    mesh: #(-1 -1  1 -1  -1 1   1 -1  1 1  -1 1) primitive: #triangles.

                faller := game addDrawable.
                faller
                    attribute: 'p' components: 2;
                    varying: 'uv' components: 2;
                    uniform: 'at' value: #(0 1);
                    image: 'icon' form: icons first;
                    vertexSource: 'void main() {
                        uv = vec2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5); ', square, '
                        gl_Position = vec4((p * 0.12 + at) * square, 0.0, 1.0); }'
                    fragmentSource: 'void main() {
                        vec4 c = texture(icon, uv);
                        if (c.a < 0.01) discard;
                        frag_color = vec4(c.rgb * c.a, c.a); }';
                    mesh: #(-1 -1  1 -1  -1 1   1 -1  1 1  -1 1) primitive: #triangles.

                at := { 0. 1 }. speed := 0.02. held := 0. score := 0.
                playing := [ [ game isDown: #escape ] whileFalse: [
                    | wanted |
                    wanted := (game pointer first max: -0.9) min: 0.9.
                    (game isDown: #left) ifTrue: [ wanted := held - 0.06 ].
                    (game isDown: #right) ifTrue: [ wanted := held + 0.06 ].
                    held := ((held * 0.6) + (wanted * 0.4) max: -0.9) min: 0.9.
                    paddle uniform: 'at' value: { held. -0.8 }.

                    at := { at first. at second - speed }.
                    faller uniform: 'at' value: at.

                    at second < -0.74 ifTrue: [
                        | caught |
                        caught := (at first - held) abs < 0.28.
                        caught
                            ifTrue: [
                                score := score + 1.
                                speed := speed + 0.002.
                                paddle uniform: 'warmth' value: (score / 20.0 min: 0.8).
                                (LumaTune named: #blip channel: 3)
                                    patch: #pulse; tempo: 320; loops: false;
                                    notes: { #b5. #e6 }; play ]
                            ifFalse: [
                                score := 0.
                                speed := 0.02.
                                paddle uniform: 'warmth' value: 0.
                                (LumaTune named: #blip channel: 3)
                                    patch: #bass; tempo: 260; loops: false;
                                    notes: { #e2. #c2 }; play ].
                        faller image: 'icon' form: icons atRandom.
                        at := { (-8 to: 8) atRandom / 10.0. 1.0 } ].

                    (Delay forMilliseconds: 33) wait ].
                    LumaTune hush ] fork.
                game
                """),
            PharoExample(
                title: "An effect over the whole view",
                code: """
                "Nothing special: a drawable whose two triangles cover the
                 view, so an effect sits among an object's views like the
                 rest of a scene."
                backdropScene := LumaCanvas new.
                backdrop := backdropScene addDrawable.
                backdrop
                    attribute: 'p' components: 2;
                    varying: 'uv' components: 2;
                    vertexSource: 'void main() {
                        uv = p * 0.5 + 0.5;
                        gl_Position = vec4(p, 0.0, 1.0); }'
                    fragmentSource: 'void main() {
                        float d = length(uv - 0.5);
                        frag_color = vec4(0.5 + 0.5 * sin(u_time + d * 24.0), uv.x, uv.y, 1.0); }';
                    mesh: #(-1 -1  1 -1  -1 1   1 -1  1 1  -1 1) primitive: #triangles.
                backdropScene
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
                title: "F\u{00FC}r Elise \u{2014} melody over chords",
                code: """
                "Beethoven, 1810, long out of copyright. The right hand runs in
                 sixteenths on one channel; the left hand's chords land on
                 another, three pitches to a step."
                LumaSynth start.
                (LumaTune named: #elise channel: 0)
                    patch: #blip; tempo: 120;
                    notes: #(e5 ds5 e5 ds5 e5 b4 d5 c5 a4 - - -
                             c4 e4 a4 b4 - - - e4 gs4 b4 c5 - - -);
                    play.
                (LumaTune named: #eliseChords channel: 1)
                    patch: #blip; tempo: 120;
                    notes: #(- - - - - - - - #(a2 e3 a3) - - -
                             - - - - #(e2 e3 gs3) - - - #(a2 e3 a3) - - -);
                    play
                """),
            PharoExample(
                title: "A chord every step",
                code: """
                "Up to four pitches share a step. Nest them and they sound
                 together."
                LumaSynth start.
                (LumaTune named: #pad channel: 3)
                    patch: #blip; tempo: 76;
                    notes: #(#(c3 e3 g3) - #(a2 c3 e3) - #(f2 a2 c3) - #(g2 b2 d3) -);
                    play
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
