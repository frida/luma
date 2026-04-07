import Foundation

public struct RGBColor: Hashable, Sendable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

public struct StyledText: Sendable, Hashable {
    public struct Span: Sendable, Hashable {
        public let text: String
        public let foreground: RGBColor?
        public let background: RGBColor?
        public let isBold: Bool

        public init(text: String, foreground: RGBColor? = nil, background: RGBColor? = nil, isBold: Bool = false) {
            self.text = text
            self.foreground = foreground
            self.background = background
            self.isBold = isBold
        }
    }

    public let spans: [Span]

    public init(spans: [Span]) {
        self.spans = spans
    }

    public init(_ plain: String) {
        self.spans = [Span(text: plain)]
    }

    public var plainText: String {
        spans.map(\.text).joined()
    }

    public var isEmpty: Bool {
        spans.allSatisfy { $0.text.isEmpty }
    }
}

public struct DisassemblyLine: Identifiable, Sendable, Hashable {
    public let address: UInt64
    public let branchTarget: UInt64?
    public let callTarget: UInt64?
    public let addressText: StyledText
    public let bytesText: StyledText
    public let asmText: StyledText
    public let commentText: StyledText?

    public var id: UInt64 { address }

    public init(
        address: UInt64,
        branchTarget: UInt64? = nil,
        callTarget: UInt64? = nil,
        addressText: StyledText,
        bytesText: StyledText,
        asmText: StyledText,
        commentText: StyledText? = nil
    ) {
        self.address = address
        self.branchTarget = branchTarget
        self.callTarget = callTarget
        self.addressText = addressText
        self.bytesText = bytesText
        self.asmText = asmText
        self.commentText = commentText
    }
}
