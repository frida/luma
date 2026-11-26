import Foundation
import LumaCore
import SwiftyPharo

#if canImport(AppKit)
import AppKit
#endif

struct Table {
    let name: String
    let columns: [PharoColumn]
    let rows: [[String]]
    let total: Int
    let expected: [Double: String]
}

struct Frontend {
    let name: String
    let chrome: Double
    let metrics: PharoTableLayout.Metrics
}

@MainActor
func check() -> Int32 {
    var complaints: [String] = []
    if PharoTableLayout.isDeclared([index, PharoColumn(title: "Item")]) {
        complaints.append("a list that declares nothing would leave the layout it has today")
    }
    for frontend in frontends {
        print("== \(frontend.name)")
        for table in tables {
            let cells = table.rows.map { row in [cell("")] + row.map(cell) }
            let layout = PharoTableLayout(columns: table.columns, rows: cells, total: table.total, metrics: frontend.metrics)
            complaints += report(table, layout, frontend) + sweep(table, layout, frontend)
        }
    }
    guard complaints.isEmpty else {
        FileHandle.standardError.write(Data((complaints.joined(separator: "\n") + "\n").utf8))
        return 1
    }
    print("every table gives way as its view declares, and stays inside its pane")
    return 0
}

func report(_ table: Table, _ layout: PharoTableLayout, _ frontend: Frontend) -> [String] {
    var complaints: [String] = []
    for width in [300.0, 470, 600, 900] {
        let widths = layout.widths(in: width - frontend.chrome)
        let seen = table.columns.indices.dropFirst().map { describe(layout.fit(of: $0, width: widths[$0])) }.joined()
        let shown = table.columns.indices.map { column in
            widths[column].map { "\(table.columns[column].title.isEmpty ? "▸" : table.columns[column].title) \(Int($0))" } ?? "-"
        }
        print("\(table.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(Int(width)) \(seen)  \(shown.joined(separator: " | "))")
        if frontend.name == "AppKit", let expected = table.expected[width], expected != seen {
            complaints.append("\(table.name) at \(Int(width)): \(seen), expected \(expected)")
        }
    }
    return complaints
}

func sweep(_ table: Table, _ layout: PharoTableLayout, _ frontend: Frontend) -> [String] {
    var complaints: [String] = []
    var previous: Set<Int> = []
    for width in stride(from: 280.0, through: 1400, by: 1) {
        let available = width - frontend.chrome
        let widths = layout.widths(in: available)
        let shown = Set(widths.indices.filter { widths[$0] != nil })
        let used = widths.compactMap { $0 }.reduce(0) { $0 + $1 + frontend.metrics.spacing }
        if used > available + 0.5 {
            complaints.append("\(frontend.name) \(table.name) at \(Int(width)): \(Int(used)) points run off the pane")
        }
        if !previous.isSubset(of: shown) {
            complaints.append("\(frontend.name) \(table.name) at \(Int(width)): widening the pane dropped a column")
        }
        previous = shown
    }
    return complaints
}

func cell(_ text: String) -> PharoCell {
    let json = text == "<icon>" ? ["png": "AA=="] : ["text": text]
    return try! JSONDecoder().decode(PharoCell.self, from: JSONSerialization.data(withJSONObject: json))
}

func describe(_ fit: PharoTableLayout.Fit) -> String {
    switch fit {
    case .whole: "W"
    case .truncated: "T"
    case .dropped: "-"
    }
}

var frontends: [Frontend] {
    var all = [
        Frontend(
            name: "GTK",
            chrome: 28,
            metrics: PharoTableLayout.Metrics(measure: { Double($0.count) * 9 }, iconWidth: 16, padding: 0, spacing: 16))
    ]
    #if canImport(AppKit)
    let font = NSFont.preferredFont(forTextStyle: .body)
    all.insert(
        Frontend(
            name: "AppKit",
            chrome: 16,
            metrics: PharoTableLayout.Metrics(
                measure: { ($0 as NSString).size(withAttributes: [.font: font]).width }, iconWidth: 16, padding: 6, spacing: 17)),
        at: 0)
    #endif
    return all
}

let index = PharoColumn(title: "Index")

func fit(_ title: String, priority: Double? = nil, minimum: Int? = nil) -> PharoColumn {
    PharoColumn(title: title, width: .fitContent, minimumCharacters: minimum, priority: priority)
}

func flexible(_ title: String, priority: Double? = nil, minimum: Int? = nil) -> PharoColumn {
    PharoColumn(title: title, minimumCharacters: minimum, priority: priority)
}

let instructions: [(String, String, String, String)] = [
    ("0x104be27f0", "stp x22, x21, [sp, -0x30]!", "", "f657bda9"),
    ("0x104be27f4", "stp x20, x19, [var_10h]", "", "f44f01a9"),
    ("0x104be27f8", "stp x29, x30, [var_20h]", "", "fd7b02a9"),
    ("0x104be27fc", "add x29, sp, 0x20", "", "fd830091"),
    ("0x104be2800", "mov x19, x1", "", "f30301aa"),
    ("0x104be2804", "mov x20, x0", "", "f40300aa"),
    ("0x104be2808", "bl gst_element_get_type", "", "a9f4ff97"),
    ("0x104be280c", "cbz x20, 0x104be2850", "; likely", "540200b4"),
    ("0x104be2810", "mov x1, x0", "", "e10300aa"),
    ("0x104be2814", "ldr x21, [x20]", "", "950240f9"),
    ("0x104be2818", "cbz x21, 0x104be2850", "; likely", "950000b4"),
    ("0x104be281c", "ldr x8, [x21]", "", "a80240f9"),
    ("0x104be2820", "cmp x8, x1", "", "1f0101eb"),
    ("0x104be2824", "b.eq 0x104be2834", "; likely", "80000054"),
    ("0x104be2828", "mov x0, x20", "", "e00314aa"),
    ("0x104be282c", "bl fcn.104c75044", "", "064a0294"),
    ("0x104be2830", "cbz w0, 0x104be2850", "; likely", "20010034"),
    ("0x104be2834", "ldr x2, [x21, 0x108]", "", "a28640f9"),
    ("0x104be2838", "cbz x2, 0x104be2858", "; likely", "020100b4"),
    ("0x104be283c", "mov x0, x20", "", "e00314aa"),
    ("0x104be2840", "mov x1, x19", "", "e10313aa"),
    ("0x104be2844", "ldp x29, x30, [var_20h]", "", "fd7b42a9"),
    ("0x104be2848", "ldp x20, x19, [var_10h]", "", "f44f41a9"),
    ("0x104be284c", "ldp x22, x21, [sp], 0x30", "", "f657c3a8"),
    ("0x104be2850", "br x2", "", "40001fd6"),
    ("0x104be2854", "bl gst_element_set_state_func", "", "4ecd0194"),
    ("0x104be2858", "mov w0, 0", "", "00008052"),
    ("0x104be285c", "ldp x29, x30, [var_20h]", "", "fd7b42a9"),
]

let tables = [
    Table(
        name: "Disassembly",
        columns: [
            index, fit("Address", priority: 2), fit("Instruction", priority: 1), flexible("Comment", priority: 3),
            fit("Bytes", priority: 4),
        ],
        rows: instructions.map { [$0.0, $0.1, $0.2, $0.3] },
        total: 33,
        expected: [300: "-W--", 470: "WWT-", 600: "WWWW", 900: "WWWW"]),
    Table(
        name: "Instructions",
        columns: [index, fit("Address", priority: 2), fit("Instruction", priority: 1), fit("Bytes", priority: 3)],
        rows: instructions.prefix(8).map { [$0.0, $0.1, $0.3] },
        total: 8,
        expected: [300: "-W-", 470: "WWW", 600: "WWW", 900: "WWW"]),
    Table(
        name: "Surroundings",
        columns: [
            index, fit("", priority: 2), fit("Address", priority: 2), fit("Instruction", priority: 1),
            fit("Bytes", priority: 3),
        ],
        rows: instructions.prefix(12).enumerated().map { [$0.offset == 5 ? "▸" : "", $0.element.0, $0.element.1, $0.element.3] },
        total: 12,
        expected: [300: "W-W-", 470: "WWW-", 600: "WWWW", 900: "WWWW"]),
    Table(
        name: "References",
        columns: [
            index, fit("From", priority: 2), fit("Kind", priority: 3), flexible("In", priority: 1, minimum: 24),
            fit("Instruction", priority: 4),
        ],
        rows: [
            ["0x104da5c3c", "CALL", "gst_bin_change_state_func", "bl gst_element_set_state"],
            ["0x104da9e10", "CALL", "reset_state", "bl gst_element_set_state"],
            ["0x104dc3a58", "CALL", "gst_element_sync_state_with_parent", "bl gst_element_set_state"],
            ["0x104e11f04", "CALL", "gst_element_change_state_func", "bl gst_element_set_state"],
            ["0x104e1a6b8", "CALL", "gst_pipeline_change_state", "bl gst_element_set_state"],
        ],
        total: 5,
        expected: [300: "--T-", 470: "WWT-", 600: "WWW-", 900: "WWWW"]),
    Table(
        name: "Objects",
        columns: [index, fit("Id", priority: 2), fit("Name", priority: 3), flexible("Object", priority: 1, minimum: 16)],
        rows: [
            ["o1", "self", "gst_element_set_state @ 0x104be27f0"],
            ["o2", "", "5"],
            [
                "o3", "",
                "#('CALL from 0x104bc4790 in gst_bin_change_state_func' 'CALL from 0x104bc8a14 in reset_state' "
                    + "'CALL from 0x104bd6e58 in gst_element_sync_state_with_parent')",
            ],
        ],
        total: 3,
        expected: [300: "W-T", 470: "WWT", 600: "WWT", 900: "WWT"]),
    Table(
        name: "Raw",
        columns: [index, fit("Variable"), flexible("Value")],
        rows: [
            ["self", "gst_element_set_state @ 0x104be27f0"],
            ["session", "gstreamer-demo"],
            ["name", "gst_element_set_state"],
            ["address", "4374538224"],
            ["detail", "/opt/homebrew/Cellar/gstreamer/1.28.8_1/lib/libgstreamer-1.0.0.dylib"],
            ["names", "an Array [0 items] ()"],
            ["arity", "8"],
            ["captures", "a Dictionary [0 items] ()"],
        ],
        total: 8,
        expected: [300: "WT", 470: "WT", 600: "WW", 900: "WW"]),
    Table(
        name: "Sessions",
        columns: [index, fit("Icon"), flexible("Name")],
        rows: [["<icon>", "gstreamer-demo"]],
        total: 1,
        expected: [300: "WW", 470: "WW", 600: "WW", 900: "WW"]),
    Table(
        name: "Modules",
        columns: [index, flexible("Name", priority: 1, minimum: 16), fit("Base", priority: 2), fit("Size", priority: 3)],
        rows: [
            ["gstreamer-demo", "0x1040f8000", "16384"],
            ["libgstreamer-1.0.0.dylib", "0x104b80000", "1146880"],
            ["libglib-2.0.0.dylib", "0x104d90000", "1458176"],
            ["libgobject-2.0.0.dylib", "0x104f30000", "311296"],
            ["libSystem.B.dylib", "0x18d6d4000", "8192"],
            ["CoreFoundation", "0x18c3e0000", "5242880"],
        ],
        total: 487,
        expected: [300: "W--", 470: "WWW", 600: "WWW", 900: "WWW"]),
    Table(
        name: "Functions",
        columns: [index, fit("Address", priority: 2), flexible("Name", priority: 1, minimum: 16), fit("Source", priority: 3)],
        rows: [
            ["0x104b9c2a0", "gst_bin_add", "export"],
            ["0x104be27f0", "gst_element_set_state", "export"],
            ["0x104bc4790", "gst_bin_change_state_func", "symbol"],
            ["0x104c1d6e4", "gst_pad_link_maybe_ghosting_full", "export"],
        ],
        total: 2210,
        expected: [300: "-T-", 470: "WTW", 600: "WWW", 900: "WWW"]),
    Table(
        name: "Threads",
        columns: [index, fit("Id"), flexible("Name")],
        rows: [["259", "main"], ["4611", "gst.task"], ["7171", "gmain"], ["9475", "queue0:src"]],
        total: 9,
        expected: [300: "WW", 470: "WW", 600: "WW", 900: "WW"]),
    Table(
        name: "Backtrace",
        columns: [index, fit("Address", priority: 2), flexible("Symbol", priority: 1, minimum: 16)],
        rows: [
            ["0x104be27f0", "libgstreamer-1.0.0.dylib!gst_element_set_state"],
            ["0x104bc4790", "libgstreamer-1.0.0.dylib!gst_bin_change_state_func"],
            ["0x1040f9a1c", "gstreamer-demo!main"],
        ],
        total: 3,
        expected: [300: "-T", 470: "WT", 600: "WW", 900: "WW"]),
    Table(
        name: "Blocks",
        columns: [index, fit("Address", priority: 1), fit("Size", priority: 2), fit("Instructions", priority: 3)],
        rows: [["0x104be27f0", "32", "8"], ["0x104be2810", "16", "4"], ["0x104be2850", "4", "1"]],
        total: 9,
        expected: [300: "WW-", 470: "WWW", 600: "WWW", 900: "WWW"]),
    Table(
        name: "Details",
        columns: [index, fit("Field"), flexible("Value")],
        rows: [
            ["Name", "libgstreamer-1.0.0.dylib"],
            ["Path", "/opt/homebrew/Cellar/gstreamer/1.28.8_1/lib/libgstreamer-1.0.0.dylib"],
            ["Base", "0x104b80000"],
            ["Size", "1146880"],
        ],
        total: 4,
        expected: [300: "WT", 470: "WT", 600: "WW", 900: "WW"]),
    Table(
        name: "Pads",
        columns: [
            index, fit("Pad", priority: 1), fit("Direction", priority: 3), fit("Kind", priority: 4), fit("Flags", priority: 5),
            flexible("Peer", priority: 2, minimum: 18),
        ],
        rows: [
            ["src", "src", "always", "fixed-caps", "queue0.sink"],
            ["sink", "sink", "always", "", "videotestsrc0.src"],
        ],
        total: 2,
        expected: [300: "W---W", 470: "WWW-W", 600: "WWWWW", 900: "WWWWW"]),
]

exit(check())
