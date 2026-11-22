import Foundation

public final class SharedBytes: @unchecked Sendable {
    public let count: Int
    public let pageSpan: Int?
    private let start: UnsafeRawPointer
    private let relinquish: @Sendable (UnsafeMutableRawPointer) -> Void

    public convenience init(copying bytes: UnsafeRawBufferPointer) {
        let storage = Storage.allocate(count: bytes.count)
        if let source = bytes.baseAddress {
            storage.start.copyMemory(from: source, byteCount: bytes.count)
        }
        self.init(storage, count: bytes.count)
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
            self.init(try Storage.mapping(descriptor, count: count), count: count)
        #endif
    }

    fileprivate init(_ storage: Storage, count: Int) {
        start = UnsafeRawPointer(storage.start)
        self.count = count
        pageSpan = storage.pageSpan
        relinquish = storage.relinquish
    }

    deinit {
        relinquish(UnsafeMutableRawPointer(mutating: start))
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
}

extension SharedBytes: Equatable {
    public static func == (lhs: SharedBytes, rhs: SharedBytes) -> Bool {
        lhs === rhs
    }
}

public final class SharedBytesAssembly: @unchecked Sendable {
    public let count: Int
    public private(set) var written = 0
    private var storage: Storage?

    public init(count: Int) {
        self.count = count
        storage = Storage.allocate(count: count)
    }

    deinit {
        storage.map { $0.relinquish($0.start) }
    }

    public var isComplete: Bool {
        written == count
    }

    public func append(_ bytes: UnsafeRawBufferPointer) {
        if let source = bytes.baseAddress {
            (storage!.start + written).copyMemory(from: source, byteCount: bytes.count)
        }
        written += bytes.count
    }

    public func finish() -> SharedBytes {
        let finished = SharedBytes(storage!, count: count)
        storage = nil
        return finished
    }
}

private struct Storage {
    let start: UnsafeMutableRawPointer
    let pageSpan: Int?
    let relinquish: @Sendable (UnsafeMutableRawPointer) -> Void

    private static let pagedFrom = 64 * 1024

    static func allocate(count: Int) -> Storage {
        #if os(Windows)
            return onHeap(count: count)
        #else
            guard count >= pagedFrom else { return onHeap(count: count) }
            let span = pages(spanning: count)
            let mapped = mmap(nil, span, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)
            guard let mapped, mapped != UnsafeMutableRawPointer(bitPattern: -1) else {
                fatalError("could not map \(span) bytes: \(String(cString: strerror(errno)))")
            }
            return Storage(start: mapped, pageSpan: span) { munmap($0, span) }
        #endif
    }

    #if !os(Windows)
        static func mapping(_ descriptor: Int32, count: Int) throws -> Storage {
            let span = pages(spanning: count)
            let mapped = mmap(nil, span, PROT_READ, MAP_PRIVATE, descriptor, 0)
            guard let mapped, mapped != UnsafeMutableRawPointer(bitPattern: -1) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return Storage(start: mapped, pageSpan: span) { munmap($0, span) }
        }
    #endif

    private static func onHeap(count: Int) -> Storage {
        Storage(start: UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 16), pageSpan: nil) {
            $0.deallocate()
        }
    }

    #if !os(Windows)
        private static func pages(spanning count: Int) -> Int {
            let pageSize = Int(getpagesize())
            return (count + pageSize - 1) / pageSize * pageSize
        }
    #endif
}
