import LumaCore
import Metal

nonisolated final class CanvasBufferStore {
    private let device: MTLDevice
    private var held: [ObjectIdentifier: (bytes: SharedBytes, buffer: MTLBuffer)] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    func buffer(holding bytes: SharedBytes) -> MTLBuffer? {
        if let existing = held[ObjectIdentifier(bytes)] {
            return existing.buffer
        }
        guard let made = makeBuffer(holding: bytes) else { return nil }
        held[ObjectIdentifier(bytes)] = (bytes, made)
        return made
    }

    func keep(onlyWhat geometries: [CanvasGeometry]) {
        let wanted = Set(geometries.flatMap { [$0.vertices?.bytes, $0.indices?.bytes] }.compactMap { $0.map(ObjectIdentifier.init) })
        held = held.filter { wanted.contains($0.key) }
    }

    private func makeBuffer(holding bytes: SharedBytes) -> MTLBuffer? {
        bytes.withUnsafeBytes { held in
            if device.hasUnifiedMemory, let pageSpan = bytes.pageSpan,
               let wrapped = device.makeBuffer(
                   bytesNoCopy: UnsafeMutableRawPointer(mutating: held.baseAddress!),
                   length: pageSpan,
                   options: .storageModeShared,
                   deallocator: nil)
            {
                return wrapped
            }
            return device.makeBuffer(bytes: held.baseAddress!, length: max(held.count, 1), options: [])
        }
    }
}

nonisolated struct CanvasGeometryBuffers {
    let vertices: Placed
    let indices: Placed?

    struct Placed {
        let buffer: MTLBuffer
        let offset: Int
    }

    init?(_ geometry: CanvasGeometry, from store: CanvasBufferStore) {
        guard geometry.vertexCount > 0, let run = geometry.vertices, let vertices = Self.place(run, in: store) else {
            return nil
        }
        self.vertices = vertices
        indices = geometry.indices.flatMap { Self.place($0, in: store) }
    }

    private static func place(_ run: CanvasBytes, in store: CanvasBufferStore) -> Placed? {
        store.buffer(holding: run.bytes).map { Placed(buffer: $0, offset: run.offset) }
    }
}

nonisolated extension MTLRenderCommandEncoder {
    func draw(_ geometry: CanvasGeometry, from buffers: CanvasGeometryBuffers) {
        setVertexBuffer(buffers.vertices.buffer, offset: buffers.vertices.offset, index: ShaderEffectRenderer.vertexBufferIndex)
        guard let indices = buffers.indices else {
            drawPrimitives(type: geometry.primitive.metal, vertexStart: 0, vertexCount: geometry.vertexCount)
            return
        }
        guard geometry.indexCount > 0 else { return }

        if geometry.drawsTriangleEdges {
            setTriangleFillMode(.lines)
        }
        drawIndexedPrimitives(
            type: geometry.drawsTriangleEdges ? .triangle : geometry.primitive.metal,
            indexCount: geometry.indexCount,
            indexType: .uint32,
            indexBuffer: indices.buffer,
            indexBufferOffset: indices.offset)
        if geometry.drawsTriangleEdges {
            setTriangleFillMode(.fill)
        }
    }
}

nonisolated extension CanvasGeometry.Primitive {
    var metal: MTLPrimitiveType {
        switch self {
        case .points: return .point
        case .lines: return .line
        case .lineStrip: return .lineStrip
        case .triangles: return .triangle
        case .triangleStrip: return .triangleStrip
        }
    }
}
