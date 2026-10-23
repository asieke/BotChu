import AppKit
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    /// What a paste or drop gives a draft: an image the pasteboard offers alone or ahead of any
    /// text (a screenshot, a browser's Copy Image), and image files; and what pastes as text: text
    /// that comes with a picture of itself (a spreadsheet's cells), and files that aren't images.
    /// Images are kept as PNG, at most 2048 pixels on a side, and a sheet holds up to eight.
    @Test func pastesImagesAndLeavesTextAndOtherFilesToPaste() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-paste-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let board = NSPasteboard.withUniqueName()
        defer {
            board.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }
        let image = NSImage(size: NSSize(width: 30, height: 20))
        image.lockFocus(); NSColor.systemGreen.setFill(); NSRect(x: 0, y: 0, width: 30, height: 20).fill(); image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let text = Data("A1\tB1".utf8)
        func offer(_ items: [[(NSPasteboard.PasteboardType, Data)]]) {
            board.clearContents()
            board.writeObjects(items.map { types in
                let item = NSPasteboardItem()
                for (type, data) in types { item.setData(data, forType: type) }
                return item
            })
        }

        // A screenshot: the picture alone.
        offer([[(.png, png)]])
        #expect(ImagePaste.hasImages(on: board))
        #expect(ImagePaste.images(on: board)?.count == 1)
        // A browser's Copy Image: markup, then the picture (Chrome), or the picture first (Safari).
        offer([[(.html, Data(#"<img src="https://example.com/a.png">"#.utf8)), (.png, png)]])
        #expect(ImagePaste.images(on: board)?.count == 1)
        offer([[(.tiff, tiff), (.string, text)]])
        #expect(ImagePaste.images(on: board)?.count == 1)
        // A spreadsheet's cells: their text, then a picture of them.
        offer([[(.string, text), (.rtf, text), (.tiff, tiff)]])
        #expect(!ImagePaste.hasImages(on: board))
        #expect(ImagePaste.images(on: board) == nil)
        // Two copied pictures.
        offer([[(.png, png)], [(.tiff, tiff)]])
        #expect(ImagePaste.images(on: board)?.count == 2)

        // Files: images attach, others paste as text.
        let picture = root.appendingPathComponent("Shot.png")
        try png.write(to: picture)
        let notes = root.appendingPathComponent("notes.txt")
        try text.write(to: notes)
        board.clearContents()
        board.writeObjects([notes as NSURL])
        #expect(!ImagePaste.hasImages(on: board))
        #expect(ImagePaste.images(on: board) == nil)
        board.clearContents()
        board.writeObjects([notes as NSURL, picture as NSURL])
        let files = try #require(ImagePaste.images(on: board))
        guard files.count == 1, case .file(let url) = files[0] else {
            Issue.record("Expected the one image file, got \(files)")
            return
        }
        #expect(url.lastPathComponent == "Shot.png")

        // Kept as PNG, at most 2048 pixels on a side; what isn't an image is refused.
        let wide = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3000, pixelsHigh: 1500, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0)?.representation(using: .jpeg, properties: [:]))
        let kept = try #require(NSBitmapImageRep(data: try ImagePaste.png(from: wide)))
        #expect(kept.pixelsWide == 2048 && kept.pixelsHigh == 1024)
        #expect(throws: ImageDelivery.Failure.self) { try ImagePaste.png(from: text) }

        // A sheet's images: up to eight, and why not more.
        let draft = DraftImages()
        offer([[(.png, png)]])
        for _ in 0..<9 { #expect(draft.paste(board)) }
        #expect(draft.images.count == ImageAttachment.maximumCount)
        #expect(draft.problem == "Attach up to 8 images.")
        draft.remove(draft.images[0].id)
        #expect(draft.images.count == 7 && draft.problem == nil)
        #expect(draft.images.allSatisfy { $0.preview != nil && $0.name == "Pasted image" })
        offer([[(.string, text)]])
        #expect(!draft.paste(board))
        #expect(draft.images.count == 7)
    }
}
