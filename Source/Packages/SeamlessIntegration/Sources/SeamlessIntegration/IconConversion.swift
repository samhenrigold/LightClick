import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a guest's icon into a current `.icns`. ImageIO reads every generation's icon families, including `it32` and the
/// `TOC ` form. Old icons stop at 128 or 256 points, so each larger size is scaled from the largest there is, keeping the
/// Dock from drawing a soft small image.
public enum IconConversion {
    public enum Failure: Error { case unreadable, unwritable }

    static let sizes = [16, 32, 48, 128, 256, 512, 1024]

    public static func convert(_ source: URL, to output: URL) throws {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil) else { throw Failure.unreadable }
        var images: [Int: CGImage] = [:]
        for index in 0..<CGImageSourceGetCount(input) {
            guard let image = CGImageSourceCreateImageAtIndex(input, index, nil) else { continue }
            images[image.width] = image
        }
        guard let largest = images.keys.max(), largest >= 16, let best = images[largest] else {
            throw Failure.unreadable
        }
        guard
            let destination = CGImageDestinationCreateWithURL(
                output as CFURL, UTType.icns.identifier as CFString, sizes.count, nil)
        else { throw Failure.unwritable }
        for size in sizes {
            guard let image = images[size] ?? scaled(best, to: size) else { throw Failure.unwritable }
            CGImageDestinationAddImage(destination, image, nil)
        }
        guard CGImageDestinationFinalize(destination) else { throw Failure.unwritable }
    }

    /// The width of the largest image in an icon file, which is what limits how sharp its tile can be.
    public static func largestSize(of icon: URL) -> Int? {
        guard let input = CGImageSourceCreateWithURL(icon as CFURL, nil) else { return nil }
        return (0..<CGImageSourceGetCount(input))
            .compactMap { CGImageSourceCreateImageAtIndex(input, $0, nil)?.width }.max()
    }

    static func scaled(_ image: CGImage, to size: Int) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()
    }
}
