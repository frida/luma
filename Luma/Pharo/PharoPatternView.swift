import LumaCore
import SwiftUI

struct PharoPatternView: View {
    let kind: Kind
    let reference: String

    enum Kind {
        case bytes
        case visualization
    }

    var body: some View {
        if let target = PharoPatternTarget(reference: reference) {
            switch kind {
            case .bytes:
                PharoPatternBytes(target: target)
            case .visualization:
                PharoPatternVisualization(target: target)
            }
        } else {
            ContentUnavailableView("The host no longer holds this value", systemImage: "square.dashed")
        }
    }
}

private struct PharoPatternTarget {
    let decoding: PharoPatternDecoding
    let node: DecodedPattern

    init?(reference: String) {
        let parts = reference.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, let decoding = PharoPatternRegistry.shared.decoding(withID: parts[0]),
            let node = decoding.root.descendant(withNodeID: UInt(parts[1]))
        else { return nil }
        self.decoding = decoding
        self.node = node
    }
}

private struct PharoPatternBytes: View {
    let target: PharoPatternTarget

    var body: some View {
        let locations = self.locations
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                HexView(
                    data: target.decoding.data,
                    baseAddress: target.decoding.address,
                    annotations: locations.values.filter(\.isLeaf).map(\.annotation),
                    emphasis: locations[target.node.id]?.annotation
                ) {
                    EmptyView()
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(8)
            }
            .onAppear {
                if let start = locations[target.node.id]?.range.lowerBound {
                    proxy.scrollTo(start / HexLayout.bytesPerRow, anchor: .top)
                }
            }
        }
    }

    private var locations: [UUID: PatternLocation] {
        var located: [UUID: PatternLocation] = [:]
        PatternLocation.locateFields(
            of: target.decoding.root, under: target.decoding.root.id, base: target.decoding.address, into: &located)
        return located
    }
}

private struct PharoPatternVisualization: View {
    let target: PharoPatternTarget

    var body: some View {
        switch outcome {
        case .success(let visualization):
            ScrollView([.horizontal, .vertical]) {
                PatternVisualizationView(visualization: visualization)
            }
        case .failure(let error):
            Text(error.localizedDescription)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.red)
                .padding(8)
        }
    }

    private var outcome: Result<PatternVisualization, Error> {
        Result { try PatternVisualization(target.node.visualizer!, of: target.node, in: target.decoding.root) }
    }
}
