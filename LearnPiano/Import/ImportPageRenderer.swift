import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import UIKit
import UniformTypeIdentifiers

/// Turns PDFs and photos into `SheetPage`s: opaque white 8-bit grayscale PNGs with a long edge of 2576 px (the model's
/// high-resolution limit), shrunk step by step when the file would exceed the API's per-image size limit. All functions
/// are synchronous and thread-safe; callers run them off the main actor.
enum ImportPageRenderer {
    static let longEdge: CGFloat = 2576
    /// PDFs longer than this are refused (each page is one API request).
    static let maxPages = 40

    /// Size scaled so its long edge is `longEdge` (or unchanged when it is already smaller and upscaling is off).
    static func targetSize(for size: CGSize, longEdge: CGFloat = longEdge, allowUpscale: Bool) -> CGSize {
        let long = max(size.width, size.height)
        guard long > 0, size.width > 0, size.height > 0 else { return .zero }
        let scale = (allowUpscale || long > longEdge) ? longEdge / long : 1
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }

    // MARK: PDF

    /// Renders every page of a PDF; `firstIndex` numbers the pages when several files are combined.
    static func renderPDF(data: Data, firstIndex: Int = 0, isCancelled: () -> Bool = { false }) throws -> [SheetPage] {
        guard let document = PDFDocument(data: data) else { throw ImportError.malformed("The PDF could not be opened.") }
        if document.isLocked { throw ImportError.malformed("The PDF is password-protected. Remove the password and try again.") }
        guard document.pageCount > 0 else { throw ImportError.empty }
        guard document.pageCount <= maxPages else {
            throw ImportError.unsupportedFormat("this PDF has \(document.pageCount) pages; LearnPiano transcribes up to \(maxPages) pages at a time. Split it into shorter files.")
        }
        var pages: [SheetPage] = []
        for i in 0..<document.pageCount {
            if isCancelled() { throw ImportError.cancelled }
            guard let page = document.page(at: i)?.pageRef else { throw ImportError.malformed("Page \(i + 1) of the PDF could not be read.") }
            pages.append(try render(pdfPage: page, index: firstIndex + i))
        }
        return pages
    }

    private static func render(pdfPage page: CGPDFPage, index: Int) throws -> SheetPage {
        let box = page.getBoxRect(.cropBox)
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        let display = (rotation == 90 || rotation == 270) ? CGSize(width: box.height, height: box.width) : box.size
        let target = targetSize(for: display, allowUpscale: true)
        guard target.width > 0, target.height > 0 else { throw ImportError.malformed("Page \(index + 1) of the PDF is empty.") }

        let encoded = encodeWithinBudget(size: target) { cg, size in
            // A CGBitmapContext is y-up like PDF space, so no flip is needed.
            cg.scaleBy(x: size.width / display.width, y: size.height / display.height)
            switch rotation {
            case 90:
                cg.translateBy(x: 0, y: display.height)
                cg.rotate(by: -.pi / 2)
            case 180:
                cg.translateBy(x: display.width, y: display.height)
                cg.rotate(by: .pi)
            case 270:
                cg.translateBy(x: display.width, y: 0)
                cg.rotate(by: .pi / 2)
            default:
                break
            }
            cg.translateBy(x: -box.minX, y: -box.minY)
            cg.clip(to: box)
            cg.drawPDFPage(page)
        }
        guard let encoded else { throw ImportError.malformed("Page \(index + 1) of the PDF could not be converted to PNG.") }
        return SheetPage(index: index, png: encoded.png, pixelWidth: encoded.width, pixelHeight: encoded.height)
    }

    // MARK: Encoding within the byte budget

    /// PNG bytes allowed per page: the API refuses images over 5 MB of base64 (4/3 of the bytes), so 3.7 MB leaves room.
    static let maxPNGBytes = 3_700_000
    /// Each over-budget attempt redraws with the long edge multiplied by this factor…
    static let budgetShrinkFactor: CGFloat = 0.85
    /// …but never below this long edge (smaller pages lose detail the model needs).
    static let minBudgetLongEdge: CGFloat = 1600

    /// Draws into an 8-bit grayscale, opaque white bitmap (sheet music needs no colour; PNGs come out about 3x
    /// smaller than RGB) and encodes PNG. While the file is over `maxBytes`, redraws at `shrinkFactor` of the long
    /// edge, stopping at `minLongEdge`. `draw` receives a y-up context of the given pixel size, already filled white.
    static func encodeWithinBudget(size initial: CGSize, maxBytes: Int = maxPNGBytes, shrinkFactor: CGFloat = budgetShrinkFactor,
                                   minLongEdge: CGFloat = minBudgetLongEdge,
                                   draw: (CGContext, CGSize) -> Void) -> (png: Data, width: Int, height: Int)? {
        var size = CGSize(width: max(1, initial.width.rounded()), height: max(1, initial.height.rounded()))
        while true {
            guard let png = grayPNG(size: size, draw: draw) else { return nil }
            let long = max(size.width, size.height)
            guard png.count > maxBytes, long > minLongEdge else { return (png, Int(size.width), Int(size.height)) }
            let nextLong = max(minLongEdge, (long * shrinkFactor).rounded(.down))
            size = targetSize(for: size, longEdge: nextLong, allowUpscale: false)
        }
    }

    /// One grayscale draw + PNG encode (CGImageDestination, so the PNG keeps its single gray channel).
    static func grayPNG(size: CGSize, draw: (CGContext, CGSize) -> Void) -> Data? {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.saveGState()
        draw(ctx, CGSize(width: width, height: height))
        ctx.restoreGState()
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    // MARK: Images

    /// Decodes a photo or picture (any ImageIO format), applies its EXIF orientation, downscales to the long edge and
    /// flattens it onto white.
    static func renderImage(data: Data, index: Int) throws -> SheetPage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw ImportError.malformed("The picture could not be decoded.")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let maxPixel = Int(min(longEdge, max(1, CGFloat(max(w, h)))))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImportError.malformed("The picture could not be decoded.")
        }
        guard let page = flatten(image, index: index) else { throw ImportError.malformed("The picture could not be converted to PNG.") }
        return page
    }

    /// Draws a CGImage on opaque white at its own pixel size (smaller when the PNG would exceed the byte budget) and
    /// encodes it as a grayscale PNG.
    static func flatten(_ image: CGImage, index: Int) -> SheetPage? {
        let size = CGSize(width: image.width, height: image.height)
        guard size.width > 0, size.height > 0 else { return nil }
        guard let encoded = encodeWithinBudget(size: size, draw: { ctx, drawSize in
            ctx.draw(image, in: CGRect(origin: .zero, size: drawSize))
        }) else { return nil }
        return SheetPage(index: index, png: encoded.png, pixelWidth: encoded.width, pixelHeight: encoded.height)
    }

    // MARK: Splitting dense pages

    /// Splits a page into a top and a bottom half at the whitest row near the middle (between two systems), so a page
    /// whose reply hit `max_tokens` can be transcribed in two requests.
    static func split(_ page: SheetPage) -> (top: SheetPage, bottom: SheetPage)? {
        guard let source = CGImageSourceCreateWithData(page.png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.height >= 64 else { return nil }
        let darkness = rowDarkness(image)
        let analysisRow = splitRow(darkness: darkness)
        let row = darkness.isEmpty ? image.height / 2 : Int((Double(analysisRow) + 0.5) / Double(darkness.count) * Double(image.height))
        let cut = max(16, min(image.height - 16, row))
        guard let topImage = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: cut)),
              let bottomImage = image.cropping(to: CGRect(x: 0, y: cut, width: image.width, height: image.height - cut)),
              let top = flatten(topImage, index: page.index), let bottom = flatten(bottomImage, index: page.index) else { return nil }
        return (top, bottom)
    }

    /// Ink per row of a downsampled grayscale copy (0 = white).
    static func rowDarkness(_ image: CGImage, analysisWidth: Int = 240) -> [Double] {
        let width = max(1, min(analysisWidth, image.width))
        let height = max(1, Int((Double(image.height) * Double(width) / Double(max(1, image.width))).rounded()))
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return [] }
        // CGContext memory is top row first.
        return (0..<height).map { y in
            var sum = 0.0
            for x in 0..<width { sum += Double(255 - pixels[y * width + x]) }
            return sum / Double(width * 255)
        }
    }

    /// The row in the middle 40 % with the least ink; ties go to the row closest to the middle.
    static func splitRow(darkness: [Double]) -> Int {
        guard !darkness.isEmpty else { return 0 }
        let n = darkness.count
        let lo = Int(Double(n) * 0.3)
        let hi = max(lo, Int(Double(n) * 0.7) - 1)
        let middle = Double(n) / 2
        var best = n / 2
        var bestValue = Double.infinity
        var bestDistance = Double.infinity
        for r in lo...hi where darkness.indices.contains(r) {
            let v = darkness[r]
            let d = abs(Double(r) - middle)
            if v < bestValue - 1e-9 || (abs(v - bestValue) <= 1e-9 && d < bestDistance) {
                best = r
                bestValue = v
                bestDistance = d
            }
        }
        return best
    }

    // MARK: Thumbnails

    /// A small preview image for the review screen.
    static func thumbnail(_ page: SheetPage, longEdge: CGFloat = 420) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(page.png as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(longEdge),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
