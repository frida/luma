import LumaCore
import SceneKit
import SwiftUI

struct PatternModelView: View {
    private let scene: SCNScene
    private let camera: SCNNode

    init(model: PatternVisualization.Model) {
        scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: Self.geometry(for: model)))
        camera = Self.camera(framing: model.vertices)
        scene.rootNode.addChildNode(camera)
    }

    var body: some View {
        SceneView(scene: scene, pointOfView: camera, options: [.allowsCameraControl, .autoenablesDefaultLighting])
            .frame(width: 400, height: 400)
    }

    private static func camera(framing vertices: [Float]) -> SCNNode {
        let positions = stride(from: 0, to: vertices.count - 2, by: 3).map { SIMD3(vertices[$0], vertices[$0 + 1], vertices[$0 + 2]) }
        let low = positions.reduce(positions[0], simd_min)
        let high = positions.reduce(positions[0], simd_max)
        let center = (low + high) / 2
        let radius = max(simd_length(high - center), .leastNormalMagnitude)

        let camera = SCNCamera()
        camera.zNear = Double(radius) * 0.01
        camera.zFar = Double(radius) * 100
        let node = SCNNode()
        node.camera = camera
        node.simdPosition = center + simd_normalize(SIMD3<Float>(1, 0.8, 1.6)) * radius * 2.8
        node.simdLook(at: center)
        return node
    }

    private static let defaultColor: [Float] = [1, 0x7f / 255, 0x33 / 255, 1]

    private static func geometry(for model: PatternVisualization.Model) -> SCNGeometry {
        let vertexCount = model.vertices.count / 3
        let indices = model.indices ?? (0..<UInt32(vertexCount - vertexCount % 3)).map { $0 }
        let normals = model.normals.count == model.vertices.count ? model.normals : smoothNormals(model.vertices, indices: indices)
        let colors =
            model.colors.count == vertexCount * 4
            ? model.colors
            : Array((0..<vertexCount).map { _ in defaultColor }.joined())

        var sources = [
            source(model.vertices, semantic: .vertex, components: 3),
            source(normals, semantic: .normal, components: 3),
            source(colors, semantic: .color, components: 4),
        ]
        if model.uv.count == vertexCount * 2 {
            sources.append(source(model.uv, semantic: .texcoord, components: 2))
        }

        let geometry = SCNGeometry(sources: sources, elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.isDoubleSided = true
        if let texturePath = model.texturePath, let texture = PlatformImage(contentsOfFile: texturePath) {
            material.diffuse.contents = texture
        }
        geometry.materials = [material]
        return geometry
    }

    private static func source(_ floats: [Float], semantic: SCNGeometrySource.Semantic, components: Int) -> SCNGeometrySource {
        let stride = components * MemoryLayout<Float>.size
        return SCNGeometrySource(
            data: floats.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: semantic, vectorCount: floats.count / components,
            usesFloatComponents: true, componentsPerVector: components, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
            dataStride: stride)
    }

    private static func smoothNormals(_ vertices: [Float], indices: [UInt32]) -> [Float] {
        let positions = stride(from: 0, to: vertices.count - 2, by: 3).map { SIMD3(vertices[$0], vertices[$0 + 1], vertices[$0 + 2]) }
        var sums = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for triangle in stride(from: 0, to: indices.count - 2, by: 3) {
            let corners = (0..<3).map { Int(indices[triangle + $0]) }
            let face = simd_cross(positions[corners[1]] - positions[corners[0]], positions[corners[2]] - positions[corners[0]])
            for corner in corners {
                sums[corner] += face
            }
        }
        return sums.flatMap { sum -> [Float] in
            let normal = simd_length(sum) > 0 ? simd_normalize(sum) : SIMD3<Float>(0, 0, 1)
            return [normal.x, normal.y, normal.z]
        }
    }
}
