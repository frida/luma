import Foundation
import Synchronization

public final class PharoBlobRegistry: Sendable {
    public static let shared = PharoBlobRegistry()

    private let state = Mutex(State())

    private struct State {
        var blobs: [Int: Blob] = [:]
        var nextID = 1
    }

    private struct Blob {
        let bytes: SharedBytes
        let lender: UUID?
        var retains: Int
    }

    public func lend(_ bytes: SharedBytes, to borrower: UUID) -> Int {
        insert(Blob(bytes: bytes, lender: borrower, retains: 1))
    }

    func adopt(_ bytes: SharedBytes) -> Int {
        insert(Blob(bytes: bytes, lender: nil, retains: 1))
    }

    public func releaseAll(lentTo borrower: UUID) {
        state.withLock { state in
            state.blobs = state.blobs.filter { $0.value.lender != borrower }
        }
    }

    func retain(_ id: Int) {
        state.withLock { state in
            state.blobs[id]?.retains += 1
        }
    }

    func release(_ id: Int) {
        state.withLock { state in
            guard var blob = state.blobs[id] else { return }
            blob.retains -= 1
            state.blobs[id] = blob.retains == 0 ? nil : blob
        }
    }

    func bytes(_ id: Int) -> SharedBytes? {
        state.withLock { $0.blobs[id]?.bytes }
    }

    func withBytes<Result>(_ id: Int, offset: Int, count: Int, _ read: (UnsafeRawBufferPointer) -> Result) -> Result? {
        guard let bytes = bytes(id), offset >= 0, count >= 0, offset + count <= bytes.count else { return nil }
        return bytes.withUnsafeBytes { read(UnsafeRawBufferPointer(rebasing: $0[offset..<(offset + count)])) }
    }

    private func insert(_ blob: Blob) -> Int {
        state.withLock { state in
            let id = state.nextID
            state.nextID += 1
            state.blobs[id] = blob
            return id
        }
    }
}

@_cdecl("luma_blob_create_copying")
public func luma_blob_create_copying(_ source: UnsafeRawPointer, _ count: Int64) -> Int32 {
    Int32(PharoBlobRegistry.shared.adopt(SharedBytes(copying: UnsafeRawBufferPointer(start: source, count: Int(max(count, 0))))))
}

@_cdecl("luma_blob_retain")
public func luma_blob_retain(_ blob: Int32) {
    PharoBlobRegistry.shared.retain(Int(blob))
}

@_cdecl("luma_blob_release")
public func luma_blob_release(_ blob: Int32) {
    PharoBlobRegistry.shared.release(Int(blob))
}

@_cdecl("luma_blob_read")
public func luma_blob_read(_ blob: Int32, _ offset: Int64, _ count: Int64, _ destination: UnsafeMutableRawPointer) -> Int32 {
    let copied = PharoBlobRegistry.shared.withBytes(Int(blob), offset: Int(offset), count: Int(count)) { bytes in
        destination.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
    }
    return copied == nil ? 0 : 1
}

@_cdecl("luma_blob_float32_extent")
public func luma_blob_float32_extent(
    _ blob: Int32,
    _ offset: Int64,
    _ count: Int64,
    _ components: Int32,
    _ extent: UnsafeMutablePointer<Float>
) -> Int32 {
    let width = Int(components)
    let found = PharoBlobRegistry.shared.withBytes(Int(blob), offset: Int(offset), count: Int(count)) { bytes -> Bool in
        guard width > 0, bytes.count % (width * 4) == 0 else { return false }
        let vectors = bytes.count / (width * 4)
        guard vectors > 0 else { return false }
        for component in 0..<width {
            extent[component] = .infinity
            extent[width + component] = -.infinity
        }
        for vector in 0..<vectors {
            for component in 0..<width {
                let value = bytes.loadUnaligned(fromByteOffset: (vector * width + component) * 4, as: Float.self)
                extent[component] = min(extent[component], value)
                extent[width + component] = max(extent[width + component], value)
            }
        }
        return true
    }
    guard let found else { return -1 }
    return found ? 1 : 0
}
