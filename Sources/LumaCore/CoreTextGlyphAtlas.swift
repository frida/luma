#if canImport(CoreText)
import CoreGraphics
import CoreText
import Foundation

/// Draws the printable range on a grid, with Core Text. What an image can
/// reach for fonts is its own business; this is the host's, and it has one.
public enum CoreTextGlyphAtlas {
    public static func install() {
        GlyphAtlasRasteriser.rasterise = { pixelSize in
            make(pixelSize: pixelSize)
        }
    }

    private nonisolated static func make(pixelSize: Int) -> GlyphAtlas? {
        // The system's own fixed-pitch face, rather than a name that may not
        // be installed and would fall back to something proportional.
        let font = CTFontCreateUIFontForLanguage(.userFixedPitch, CGFloat(pixelSize), nil)
            ?? CTFontCreateWithName("Menlo" as CFString, CGFloat(pixelSize), nil)
        let codes = Array(GlyphAtlas.first...GlyphAtlas.last)
        let advances = codes.map { Float(advance(of: $0, in: font).width.rounded(.up)) }

        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        // A guard texel each side, so a cell is never sampled into its
        // neighbour, and whole texels so it is sampled on its own grid.
        let widest = advances.max() ?? Float(pixelSize)
        let cellWidth = Int(widest.rounded(.up)) + 2
        let cellHeight = Int((ascent + descent).rounded(.up)) + 2
        let columns = 16
        let rows = (codes.count + columns - 1) / columns

        let width = cellWidth * columns
        let height = cellHeight * rows
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        context.setAllowsAntialiasing(true)
        context.setShouldSmoothFonts(false)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

        for (index, code) in codes.enumerated() {
            guard let scalar = Unicode.Scalar(UInt32(code)) else { continue }

            var glyph = CGGlyph()
            var character = UniChar(scalar.value)
            guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else { continue }

            // Core Graphics counts rows from the bottom; the cells are laid
            // out from the top, as the sampling reads them.
            let column = index % columns
            let row = index / columns
            let at = CGPoint(
                x: CGFloat(column * cellWidth + 1),
                y: CGFloat(height - (row + 1) * cellHeight + 1) + descent)
            withUnsafePointer(to: at) { origin in
                CTFontDrawGlyphs(font, &glyph, origin, 1, context)
            }
        }

        guard let pixels = context.data else { return nil }
        let words = UnsafeBufferPointer(
            start: pixels.assumingMemoryBound(to: UInt32.self), count: width * height)
        // The rows are already the way they are read: a bitmap context
        // stores its first row at the top even though it draws from the
        // bottom, so what is drawn into the top band is what is sampled there.
        let sheet = Array(words)
        let band = ink(of: sheet, width: width, cellHeight: cellHeight)

        return GlyphAtlas(
            pixels: sheet,
            width: width,
            height: height,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            columns: columns,
            inkTop: band.lowerBound,
            inkBottom: band.upperBound,
            advances: advances)
    }

    private nonisolated static func advance(of code: Int, in font: CTFont) -> CGSize {
        guard let scalar = Unicode.Scalar(UInt32(code)) else { return .zero }

        var glyph = CGGlyph()
        var character = UniChar(scalar.value)
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else { return .zero }

        var size = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &size, 1)
        return size
    }

    /// Which rows of a cell the lettering touches. Every cell shares a
    /// baseline, so one pass answers for all of them.
    private nonisolated static func ink(of pixels: [UInt32], width: Int, cellHeight: Int) -> ClosedRange<Int> {
        var top = cellHeight
        var bottom = 0
        for (index, pixel) in pixels.enumerated() where pixel != 0 {
            let row = (index / width) % cellHeight
            top = min(top, row)
            bottom = max(bottom, row)
        }
        guard top <= bottom else { return 0...cellHeight }
        return top...(bottom + 1)
    }
}
#endif
