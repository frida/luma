import Foundation

public final class SharedBytes: @unchecked Sendable {
    public let count: Int
    private let start: UnsafeRawPointer
    private let relinquish: @Sendable (UnsafeMutableRawPointer, Int) -> Void

    public convenience init(copying bytes: UnsafeRawBufferPointer) {
        let start = Self.allocate(count: bytes.count)
        if let source = bytes.baseAddress {
            start.copyMemory(from: source, byteCount: bytes.count)
        }
        self.init(start: start, count: bytes.count, relinquish: Self.deallocate)
    }

    public convenience init(copying bytes: some ContiguousBytes) {
        self.init(copying: bytes.withUnsafeBytes { UnsafeRawBufferPointer($0) })
    }

    public convenience init(mapping url: URL) throws {
        #if os(Windows)
            self.init(copying: try Data(contentsOf: url))
        #else
            let descriptor = open(url.path, O_RDONLY)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let count = Int(status.st_size)
            guard count > 0 else {
                self.init(copying: UnsafeRawBufferPointer(start: nil, count: 0))
                return
            }
            let mapped = mmap(nil, count, PROT_READ, MAP_PRIVATE, descriptor, 0)
            guard let mapped, mapped != UnsafeMutableRawPointer(bitPattern: -1) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            self.init(start: mapped, count: count) { munmap($0, $1) }
        #endif
    }

    init(start: UnsafeMutableRawPointer, count: Int, relinquish: @escaping @Sendable (UnsafeMutableRawPointer, Int) -> Void) {
        self.start = UnsafeRawPointer(start)
        self.count = count
        self.relinquish = relinquish
    }

    deinit {
        relinquish(UnsafeMutableRawPointer(mutating: start), count)
    }

    public func withUnsafeBytes<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) rethrows -> Result {
        try body(UnsafeRawBufferPointer(start: start, count: count))
    }

    public func bytes(in range: Range<Int>) -> [UInt8] {
        withUnsafeBytes { [UInt8]($0[range]) }
    }

    public var array: [UInt8] {
        bytes(in: 0..<count)
    }

    fileprivate static func allocate(count: Int) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 16)
    }

    fileprivate static let deallocate: @Sendable (UnsafeMutableRawPointer, Int) -> Void = { start, _ in
        start.deallocate()
    }
}

extension SharedBytes: Equatable {
    public static func == (lhs: SharedBytes, rhs: SharedBytes) -> Bool {
        lhs === rhs
    }
}

public final class SharedBytesAssembly: @unchecked Sendable {
    public let count: Int
    public private(set) var written = 0
    private var start: UnsafeMutableRawPointer?

    public init(count: Int) {
        self.count = count
        start = SharedBytes.allocate(count: count)
    }

    deinit {
        start.map { SharedBytes.deallocate($0, count) }
    }

    public var isComplete: Bool {
        written == count
    }

    public func append(_ bytes: UnsafeRawBufferPointer) {
        if let source = bytes.baseAddress {
            (start! + written).copyMemory(from: source, byteCount: bytes.count)
        }
        written += bytes.count
    }

    public func finish() -> SharedBytes {
        let finished = SharedBytes(start: start!, count: count, relinquish: SharedBytes.deallocate)
        start = nil
        return finished
    }
}
