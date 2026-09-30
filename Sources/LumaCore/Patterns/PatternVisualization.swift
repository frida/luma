import Foundation
import Frida

public struct DecodedVisualizer: Sendable {
    public let name: String
    public let presentation: Presentation
    public let arguments: [Argument]

    public enum Presentation: Sendable {
        case detached
        case inline
    }

    public enum Argument: Sendable {
        case value(DecodedScalar?)
        case pattern(PatternArgument)
    }

    public struct PatternArgument: Sendable {
        public let nodeID: UInt?
        public let value: DecodedScalar?
        public let address: UInt64
        public let data: Data
    }

    init(_ visualizer: PatternVisualizer) {
        name = visualizer.name
        presentation = visualizer.presentation == .inline ? .inline : .detached
        arguments = visualizer.arguments.map(Argument.init)
    }
}

extension DecodedVisualizer.Argument {
    init(_ argument: PatternVisualizerArgument) {
        let value = argument.value.flatMap(DecodedScalar.init)
        switch argument.kind {
        case .value:
            self = .value(value)
        case .pattern:
            self = .pattern(
                DecodedVisualizer.PatternArgument(
                    nodeID: argument.pattern == 0 ? nil : argument.pattern,
                    value: value,
                    address: argument.address,
                    data: Data(argument.data ?? [])))
        }
    }
}

public enum PatternVisualization: Sendable {
    case linePlot([Float])
    case scatterPlot(x: [Float], y: [Float])
    case image(Data)
    case bitmap(Bitmap)
    case model(Model)
    case sound(Sound)
    case coordinates(latitude: Double, longitude: Double)
    case timestamp(Date)
    case table(Table)
    case digitalSignal([SignalSegment])
    case hexViewer(Data, address: UInt64)
    case chunkEntropy(ChunkEntropy)
    case disassembly(Disassembly)
    case color(red: Double, green: Double, blue: Double, alpha: Double)
    case gauge(Double)
    case button(function: String, label: String)

    public struct Bitmap: Sendable {
        public let width: Int
        public let height: Int
        public let rgba: Data
    }

    public struct Model: Sendable {
        public let vertices: [Float]
        public let indices: [UInt32]?
        public let normals: [Float]
        public let colors: [Float]
        public let uv: [Float]
        public let texturePath: String?
    }

    public struct Sound: Sendable {
        public let samples: [Int16]
        public let channels: Int
        public let sampleRate: Int
    }

    public struct Table: Sendable {
        public let columns: Int
        public let rows: Int
        public let cells: [String]

        public func cell(row: Int, column: Int) -> String {
            let index = row * columns + column
            return index < cells.count ? cells[index] : "??"
        }
    }

    public struct SignalSegment: Sendable {
        public let label: String
        public let value: String
        public let color: String?
        public let bits: Int
        public let isHigh: Bool
    }

    public struct ChunkEntropy: Sendable {
        public let chunkSize: Int
        public let values: [Double]
    }

    public struct Disassembly: Sendable {
        public let data: Data
        public let address: UInt64
        public let architecture: String
    }

    public init(_ visualizer: DecodedVisualizer, of owner: DecodedPattern, in root: DecodedPattern) throws {
        let arguments = VisualizerArguments(name: visualizer.name, values: visualizer.arguments, root: root)
        switch visualizer.name {
        case "line_plot":
            try arguments.expect(1)
            self = .linePlot(try arguments.pattern(0).data.elements(of: Float.self))
        case "scatter_plot":
            try arguments.expect(2)
            self = .scatterPlot(
                x: try arguments.pattern(0).data.elements(of: Float.self), y: try arguments.pattern(1).data.elements(of: Float.self))
        case "image":
            try arguments.expect(1)
            self = .image(try arguments.pattern(0).data)
        case "bitmap":
            try arguments.expect(3...4)
            self = .bitmap(try Self.bitmap(arguments))
        case "3d":
            try arguments.expect(2...6)
            self = .model(try Self.model(arguments))
        case "sound":
            try arguments.expect(3)
            self = .sound(try Self.sound(arguments))
        case "coordinates":
            try arguments.expect(2)
            self = .coordinates(latitude: try arguments.number(0), longitude: try arguments.number(1))
        case "timestamp":
            try arguments.expect(1)
            self = .timestamp(Date(timeIntervalSince1970: try arguments.number(0)))
        case "table":
            try arguments.expect(3)
            self = .table(try Self.table(arguments))
        case "digital_signal":
            try arguments.expect(1)
            self = .digitalSignal(try Self.signal(arguments))
        case "hex_viewer":
            try arguments.expect(1)
            let pattern = try arguments.pattern(0)
            self = .hexViewer(pattern.data, address: pattern.address)
        case "chunk_entropy":
            try arguments.expect(2)
            let chunkSize = try arguments.count(1)
            self = .chunkEntropy(
                ChunkEntropy(chunkSize: chunkSize, values: try Self.chunkEntropy(of: arguments.pattern(0).data, chunkSize: chunkSize)))
        case "disassembler":
            try arguments.expect(3)
            self = .disassembly(
                Disassembly(
                    data: try arguments.pattern(0).data, address: UInt64(try arguments.number(1)), architecture: try arguments.string(2)))
        case "color":
            try arguments.expect(4)
            self = .color(
                red: try arguments.number(0) / 255, green: try arguments.number(1) / 255, blue: try arguments.number(2) / 255,
                alpha: try arguments.number(3) / 255)
        case "gauge":
            try arguments.expect(1)
            self = .gauge(try arguments.number(0) / 100)
        case "button":
            try arguments.expect(1)
            self = .button(function: try arguments.string(0), label: owner.summary)
        default:
            throw PatternVisualizationError("Unknown visualizer \"\(visualizer.name)\".")
        }
    }

    private static func bitmap(_ arguments: VisualizerArguments) throws -> Bitmap {
        let pixels = try arguments.pattern(0).data
        let width = try arguments.count(1)
        let height = try arguments.count(2)
        if arguments.values.count == 4 {
            let colorTable = try arguments.pattern(3).data
            if !colorTable.isEmpty {
                return Bitmap(width: width, height: height, rgba: palettized(pixels, width: width, height: height, colorTable: colorTable))
            }
        }
        guard pixels.count >= width * height * 4 else {
            throw PatternVisualizationError(
                "A \(width)×\(height) bitmap needs \(width * height * 4) bytes of RGBA, but got \(pixels.count).")
        }
        return Bitmap(width: width, height: height, rgba: pixels.prefix(width * height * 4))
    }

    private static func palettized(_ pixels: Data, width: Int, height: Int, colorTable: Data) -> Data {
        let colors = colorTable.count / 4
        var rgba = Data(capacity: width * height * 4)
        for index in paletteIndices(pixels, count: width * height) {
            let entry = index < colors ? index : 0
            rgba.append(colorTable[colorTable.startIndex + entry * 4..<colorTable.startIndex + entry * 4 + 4])
        }
        return rgba
    }

    private static func paletteIndices(_ pixels: Data, count: Int) -> [Int] {
        guard !pixels.isEmpty, count > 0 else { return [] }
        if pixels.count >= count {
            switch pixels.count / count {
            case 1:
                return pixels.map(Int.init)
            case 2:
                return pixels.elements(of: UInt16.self).map(Int.init)
            default:
                return []
            }
        }
        guard count / pixels.count == 2 else { return [] }
        return pixels.flatMap { [Int($0 & 0xf), Int($0 >> 4)] }
    }

    private static func model(_ arguments: VisualizerArguments) throws -> Model {
        let vertices = try arguments.pattern(0).data.elements(of: Float.self)
        guard vertices.count >= 3, vertices.count % 3 == 0 else {
            throw PatternVisualizationError("Vertex positions must be a multiple of three floats, but got \(vertices.count).")
        }
        let indices = try modelIndices(arguments.node(1), data: arguments.pattern(1).data)
        if let indices {
            guard indices.count >= 3, indices.count % 3 == 0 else {
                throw PatternVisualizationError("Indices must come in triangles, but got \(indices.count).")
            }
            let vertexCount = UInt32(vertices.count / 3)
            let outOfRange = indices.filter { $0 >= vertexCount }
            guard outOfRange.isEmpty else {
                let listed = outOfRange.prefix(8).map(String.init).joined(separator: ", ")
                throw PatternVisualizationError("Indices \(listed) are out of range for \(vertexCount) vertices.")
            }
        }
        let count = arguments.values.count
        return Model(
            vertices: vertices,
            indices: indices,
            normals: count > 2 ? try arguments.pattern(2).data.elements(of: Float.self) : [],
            colors: count > 3 ? try arguments.pattern(3).data.elements(of: Float.self) : [],
            uv: count > 4 ? try arguments.pattern(4).data.elements(of: Float.self) : [],
            texturePath: count > 5 ? try arguments.string(5) : nil)
    }

    private static func modelIndices(_ node: DecodedPattern, data: Data) throws -> [UInt32]? {
        guard var entry = node.children.first else { return nil }
        while (entry.size ?? 0) == 0 {
            guard let first = entry.children.first else {
                throw PatternVisualizationError("Indices must be an array of integers.")
            }
            entry = first
        }
        switch entry.size {
        case 1:
            return data.map(UInt32.init)
        case 2:
            return data.elements(of: UInt16.self).map(UInt32.init)
        case 4:
            return data.elements(of: UInt32.self)
        default:
            throw PatternVisualizationError("Indices must be 8, 16 or 32 bits wide.")
        }
    }

    private static func sound(_ arguments: VisualizerArguments) throws -> Sound {
        let channels = try arguments.count(1)
        let sampleRate = try arguments.count(2)
        guard channels > 0 else { throw PatternVisualizationError("A sound needs at least one channel.") }
        guard sampleRate > 0 else { throw PatternVisualizationError("A sound needs a sample rate.") }
        return Sound(samples: try arguments.pattern(0).data.elements(of: Int16.self), channels: channels, sampleRate: sampleRate)
    }

    private static func table(_ arguments: VisualizerArguments) throws -> Table {
        let array = try arguments.node(0)
        guard array.fields.isEmpty else {
            throw PatternVisualizationError("The table visualizer needs an array.")
        }
        return Table(columns: try arguments.count(1), rows: try arguments.count(2), cells: array.elements.map(\.summary))
    }

    private static func signal(_ arguments: VisualizerArguments) throws -> [SignalSegment] {
        let bitfield = try arguments.node(0)
        guard !bitfield.fields.isEmpty, bitfield.fields.allSatisfy({ $0.bitOffset != nil }) else {
            throw PatternVisualizationError("The digital signal visualizer needs a bitfield.")
        }
        return bitfield.fields.map { field in
            SignalSegment(
                label: field.displayName ?? field.name,
                value: field.summary,
                color: field.color,
                bits: field.bits > 0 ? field.bits : (field.size ?? 0) * 8,
                isHigh: (field.value?.number ?? 0) > 0)
        }
    }

    private static func chunkEntropy(of data: Data, chunkSize: Int) throws -> [Double] {
        guard chunkSize > 0 else { throw PatternVisualizationError("The chunk size must be positive.") }
        return stride(from: data.startIndex, to: data.endIndex, by: chunkSize).map { start in
            normalizedEntropy(of: data[start..<min(start + chunkSize, data.endIndex)])
        }
    }

    private static func normalizedEntropy(of chunk: Data) -> Double {
        var counts = [Int](repeating: 0, count: 256)
        for byte in chunk {
            counts[Int(byte)] += 1
        }
        let total = Double(chunk.count)
        let bits = counts.reduce(0.0) { sum, count in
            guard count > 0 else { return sum }
            let probability = Double(count) / total
            return sum - probability * log2(probability)
        }
        return bits / 8
    }
}

public struct PatternVisualizationError: LocalizedError, Sendable {
    public let message: String

    init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

private struct VisualizerArguments {
    let name: String
    let values: [DecodedVisualizer.Argument]
    let root: DecodedPattern

    func expect(_ count: Int) throws {
        try expect(count...count)
    }

    func expect(_ counts: ClosedRange<Int>) throws {
        guard counts.contains(values.count) else {
            let expected = counts.count == 1 ? "\(counts.lowerBound)" : "\(counts.lowerBound) to \(counts.upperBound)"
            throw PatternVisualizationError("\(name) takes \(expected) arguments after its name, but got \(values.count).")
        }
    }

    func pattern(_ index: Int) throws -> DecodedVisualizer.PatternArgument {
        guard case .pattern(let pattern) = values[index] else {
            throw PatternVisualizationError("Argument \(index + 1) of \(name) must be a pattern.")
        }
        return pattern
    }

    func node(_ index: Int) throws -> DecodedPattern {
        guard let nodeID = try pattern(index).nodeID, let node = root.descendant(withNodeID: nodeID) else {
            throw PatternVisualizationError("Argument \(index + 1) of \(name) is not part of the decoded value.")
        }
        return node
    }

    func number(_ index: Int) throws -> Double {
        guard let number = scalar(index)?.number else {
            throw PatternVisualizationError("Argument \(index + 1) of \(name) must be a number.")
        }
        return number
    }

    func count(_ index: Int) throws -> Int {
        let number = try number(index)
        guard number >= 0, number <= Double(Int32.max) else {
            throw PatternVisualizationError("Argument \(index + 1) of \(name) must be a count, but is \(number).")
        }
        return Int(number)
    }

    func string(_ index: Int) throws -> String {
        guard case .string(let text) = scalar(index) else {
            throw PatternVisualizationError("Argument \(index + 1) of \(name) must be a string.")
        }
        return text
    }

    private func scalar(_ index: Int) -> DecodedScalar? {
        switch values[index] {
        case .value(let scalar):
            return scalar
        case .pattern(let pattern):
            return pattern.value
        }
    }
}

extension Data {
    fileprivate func elements<T: FixedWidthInteger>(of type: T.Type) -> [T] {
        withUnsafeBytes { raw in
            (0..<count / MemoryLayout<T>.size).map {
                T(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<T>.size, as: T.self))
            }
        }
    }

    fileprivate func elements(of type: Float.Type) -> [Float] {
        elements(of: UInt32.self).map(Float.init(bitPattern:))
    }
}
