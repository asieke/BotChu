import ImageIO
import os
import SwiftUI
import BotChuCore

/// Image files decoded once, at most a given number of pixels on a side, off the main thread, and
/// kept in one cache bounded in bytes: pet stills, attachment thumbnails and previews. A file
/// rewritten in place comes with a `version`, or is `reload`ed.
final class ImageThumbnails: @unchecked Sendable {
    static let shared = ImageThumbnails()

    /// Longest edges in pixels, for a Retina display. A pet's still is the size of its clip.
    static let pet = PetVideo.clipSide
    static let thumbnail = 160
    static let preview = 640
    static let card = 1280

    private let images = NSCache<NSString, CGImage>()
    private let sizes = NSCache<NSString, NSValue>()
    private let opened = OSAllocatedUnfairLock(initialState: 0)

    init(costLimit: Int = 64 << 20) { images.totalCostLimit = costLimit }

    /// How many times it has opened a file, for tests.
    var reads: Int { opened.withLock { $0 } }

    /// What is in memory: safe in a view's `body`.
    func cached(_ url: URL, pixels: Int, version: Date? = nil) -> CGImage? {
        images.object(forKey: Self.key(url, pixels, version))
    }

    /// Cached, else decoded now on this thread: for what must never be missing.
    func image(_ url: URL, pixels: Int, version: Date? = nil) -> CGImage? {
        cached(url, pixels: pixels, version: version) ?? decode(url, pixels: pixels, version: version)
    }

    /// Cached, else decoded off the main thread.
    func load(_ url: URL, pixels: Int, version: Date? = nil) async -> CGImage? {
        if let image = cached(url, pixels: pixels, version: version) { return image }
        return await Task.detached(priority: .userInitiated) { self.decode(url, pixels: pixels, version: version) }.value
    }

    /// Forgets these files at once, as they were replaced, then decodes them again in order off the
    /// main thread.
    func reload(_ urls: [URL], pixels: Int) {
        for url in urls { images.removeObject(forKey: Self.key(url, pixels, nil)) }
        Task.detached(priority: .utility) { for url in urls { _ = self.decode(url, pixels: pixels, version: nil) } }
    }

    /// Its width and height in pixels, upright, from the file's header; nil when it isn't an image.
    func pixelSize(of url: URL, version: Date? = nil) -> CGSize? {
        let key = Self.key(url, 0, version)
        if let size = sizes.object(forKey: key) { return size.sizeValue }
        guard let source = source(url),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        // EXIF orientations 5 to 8 turn it a quarter.
        let turned = (5...8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
        let size = turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        sizes.setObject(NSValue(size: size), forKey: key)
        return size
    }

    static func key(_ url: URL, _ pixels: Int, _ version: Date?) -> NSString {
        "\(pixels) \(version?.timeIntervalSinceReferenceDate ?? 0) \(url.path)" as NSString
    }

    private func decode(_ url: URL, pixels: Int, version: Date?) -> CGImage? {
        guard let source = source(url), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            // Decoded here rather than when first drawn, on the main thread.
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else { return nil }
        images.setObject(image, forKey: Self.key(url, pixels, version), cost: image.bytesPerRow * image.height)
        return image
    }

    /// Without ImageIO keeping a full-size decode of its own.
    private func source(_ url: URL) -> CGImageSource? {
        opened.withLock { $0 += 1 }
        return CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}

/// An image file shown at most `pixels` on a side: from memory at once, else decoded off the main
/// thread behind a blank the size it will take, so nothing moves when it arrives.
struct ThumbnailImage: View {
    let url: URL
    let pixels: Int
    var version: Date?
    /// What VoiceOver reads; nil hides it.
    var label: String?
    @State private var loaded: CGImage?

    var body: some View {
        let thumbnails = ImageThumbnails.shared
        let image = loaded ?? thumbnails.cached(url, pixels: pixels, version: version)
        let size = image.map { CGSize(width: $0.width, height: $0.height) }
            ?? thumbnails.pixelSize(of: url, version: version).map { full in
                let scale = min(1, CGFloat(pixels) / max(full.width, full.height))
                return CGSize(width: full.width * scale, height: full.height * scale)
            } ?? CGSize(width: 4, height: 3)
        Group {
            if let image {
                (label.map { Image(image, scale: 1, label: Text($0)) } ?? Image(decorative: image, scale: 1))
                    .resizable()
                    .interpolation(.high)
            } else {
                Color.clear.frame(idealWidth: size.width, idealHeight: size.height)
            }
        }
        .aspectRatio(size.width / size.height, contentMode: .fit)
        .task(id: ImageThumbnails.key(url, pixels, version)) {
            loaded = await thumbnails.load(url, pixels: pixels, version: version)
        }
    }
}
