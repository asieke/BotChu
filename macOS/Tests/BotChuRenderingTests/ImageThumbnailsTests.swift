import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    /// #337: a pet's 1254-pixel still decodes at its clip's size, a smaller image as it is, and the
    /// file is read once; the cache keeps to its cost limit, and a remade still replaces the old one.
    @Test func imagesDecodeOnceAtTheirShownSizeWithinTheCacheLimit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-thumbnails-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let still = folder.appendingPathComponent("idle.png"), wide = folder.appendingPathComponent("wide.png")
        let small = folder.appendingPathComponent("small.png"), text = folder.appendingPathComponent("notes.png")
        try writePNG(width: 1254, height: 1254, to: still)
        try writePNG(width: 1254, height: 627, to: wide)
        try writePNG(width: 32, height: 32, to: small)
        try Data("not an image".utf8).write(to: text)

        let thumbnails = ImageThumbnails(costLimit: 1 << 20)
        func size(_ image: CGImage?) -> [Int]? { image.map { [$0.width, $0.height] } }
        #expect(ImageThumbnails.pet == PetVideo.clipSide)
        #expect(size(thumbnails.image(still, pixels: ImageThumbnails.pet)) == [256, 256])
        #expect(size(thumbnails.image(wide, pixels: ImageThumbnails.pet)) == [256, 128])
        #expect(size(thumbnails.image(small, pixels: ImageThumbnails.pet)) == [32, 32])
        #expect(thumbnails.pixelSize(of: still) == CGSize(width: 1254, height: 1254))
        #expect(thumbnails.reads == 4)
        #expect(size(thumbnails.image(still, pixels: ImageThumbnails.pet)) == [256, 256])
        #expect(thumbnails.pixelSize(of: still) == CGSize(width: 1254, height: 1254))
        #expect(thumbnails.reads == 4)
        #expect(thumbnails.image(text, pixels: ImageThumbnails.pet) == nil && thumbnails.pixelSize(of: text) == nil)

        // Twelve 256 KB stills against a 1 MB limit: the newest stays, and no more than the limit
        // and one entry are kept.
        let versions = (0..<12).map { Date(timeIntervalSinceReferenceDate: Double($0)) }
        var costs: [Int] = []
        for version in versions {
            let image = try #require(thumbnails.image(still, pixels: ImageThumbnails.pet, version: version))
            costs.append(image.bytesPerRow * image.height)
        }
        let kept = versions.indices.filter { thumbnails.cached(still, pixels: ImageThumbnails.pet, version: versions[$0]) != nil }
        #expect(kept.contains(versions.count - 1))
        #expect(kept.map { costs[$0] }.reduce(0, +) <= (1 << 20) + costs[0], "kept \(kept)")

        // A remade still: the old one is gone at once, and the new one decodes off the main thread.
        #expect(size(thumbnails.image(still, pixels: ImageThumbnails.pet)) == [256, 256])
        try writePNG(width: 1254, height: 627, to: still)
        thumbnails.reload([still], pixels: ImageThumbnails.pet)
        #expect(size(thumbnails.cached(still, pixels: ImageThumbnails.pet)) != [256, 256])
        for _ in 0..<300 where thumbnails.cached(still, pixels: ImageThumbnails.pet) == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(size(thumbnails.cached(still, pixels: ImageThumbnails.pet)) == [256, 128])
    }

    /// #337: typing in a composer with three screenshots reads none of them again; each was read
    /// once, off the main thread, and shows.
    @Test func composerReadsNoAttachmentWhileItIsTyped() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-composer-images-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let images = (1...3).map { ImageAttachment(name: "Screenshot \($0).png") }
        var urls: [UUID: URL] = [:]
        for image in images {
            urls[image.id] = folder.appendingPathComponent(image.filename)
            try writePNG(width: 1600, height: 1000, to: urls[image.id]!)
        }
        let typed = TypedDraft()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: ComposerWithImages(images: images, urls: urls, typed: typed))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        let thumbnails = ImageThumbnails.shared
        let urlList = Array(urls.values)
        for _ in 0..<300 where urlList.contains(where: { thumbnails.cached($0, pixels: ImageThumbnails.thumbnail) == nil }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(urlList.allSatisfy { thumbnails.cached($0, pixels: ImageThumbnails.thumbnail) != nil })
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        #expect(try drawsRed(host) > 3 * 400, "the thumbnails show")

        let editor = try #require(composerTextView(in: host))
        let reads = thumbnails.reads
        let keys = String(repeating: "k", count: 20)
        for key in keys {
            editor.insertText(String(key), replacementRange: editor.selectedRange())
            try await Task.sleep(for: .milliseconds(20))
            window.layoutIfNeeded()
        }
        #expect(typed.text == keys)
        #expect(thumbnails.reads == reads)
    }

    private func writePNG(width: Int, height: Int, to url: URL) throws {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    /// How many of the view's pixels (every other one each way) are red.
    private func drawsRed(_ view: NSView) throws -> Int {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.alphaComponent > 0.9, color.redComponent - max(color.greenComponent, color.blueComponent) > 0.5 { count += 1 }
            }
        }
        return count
    }

    private func composerTextView(in view: NSView) -> ComposerTextView? {
        if let editor = view as? ComposerTextView { return editor }
        return view.subviews.lazy.compactMap { composerTextView(in: $0) }.first
    }
}

private final class TypedDraft { var text = "" }

private struct ComposerWithImages: View {
    let images: [ImageAttachment]
    let urls: [UUID: URL]
    let typed: TypedDraft
    @State private var draft = ""

    var body: some View {
        Composer(draft: $draft, focused: .constant(true), images: images, imageURL: { urls[$0.id] },
                 placeholder: "Message", running: false, onSend: {}, onStop: {}) { EmptyView() }
            .frame(width: 480)
            .onChange(of: draft) { typed.text = $1 }
    }
}
