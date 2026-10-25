import AppKit
import ImageIO
import UniformTypeIdentifiers
import BotChuCore

extension AppModel {
    func imageURL(_ image: ImageAttachment, for target: ChatTarget) -> URL? {
        bot(target.botID).map { BotHome(workspace: $0.workspace).imageURL(image) }
    }

    func addImages(_ urls: [URL], to target: ChatTarget) {
        addImages(urls.map(ImagePaste.Source.file), to: target)
    }

    /// Adds the images a paste or drop holds to the conversation's draft; false when it holds
    /// something else, such as text, which then pastes as usual.
    @discardableResult
    func pasteImages(_ pasteboard: NSPasteboard, to target: ChatTarget) -> Bool {
        guard let images = ImagePaste.images(on: pasteboard) else { return false }
        addImages(images, to: target)
        return true
    }

    func addImage(_ data: Data, name: String, to target: ChatTarget) throws {
        try addImage(.data(data, name: name), to: target)
    }

    private func addImages(_ sources: [ImagePaste.Source], to target: ChatTarget) {
        attachmentErrors[target] = nil
        for source in sources {
            do { try addImage(source, to: target) } catch { attachmentErrors[target] = error.localizedDescription }
        }
    }

    private func addImage(_ source: ImagePaste.Source, to target: ChatTarget) throws {
        guard let bot = bot(target.botID) else { return }
        guard (draftImages[target]?.count ?? 0) < ImageAttachment.maximumCount else { throw ImageDelivery.Failure("Attach up to 8 images per message.") }
        let image = try ImagePaste.png(from: source)
        let saved = try BotHome(workspace: bot.workspace).saveImage(image.png, name: image.name)
        draftImages[target, default: []].append(saved)
    }
}

/// The images a draft takes from a paste, a drop or a file, decoded here and kept as PNG, at most
/// 2048 pixels on the longest edge. Re-encoding leaves the original's metadata behind, such as
/// where a photo was taken.
enum ImagePaste {
    /// An image as it is given: a file, or its data.
    enum Source {
        case file(URL)
        case data(Data, name: String)
    }

    /// Larger files aren't read.
    static let maximumBytes = 30 * 1024 * 1024

    /// The images a paste or drop gives a draft, or nil when it holds something else, such as text,
    /// which then pastes as it would anywhere. Image files come as files (as Finder copies them),
    /// and other files paste as text; otherwise each item gives the image it offers ahead of any
    /// text (`imageType(in:)`).
    static func images(on pasteboard: NSPasteboard) -> [Source]? {
        if let files = fileURLs(on: pasteboard) {
            let images = files.filter(isImageFile)
            return images.isEmpty ? nil : images.map(Source.file)
        }
        let found = (pasteboard.pasteboardItems ?? []).compactMap { item in
            imageType(in: item.types).flatMap { item.data(forType: $0) }
        }
        return found.isEmpty ? nil : found.map { .data($0, name: "Pasted image") }
    }

    /// Whether a drop gives images, without reading them. It reads the files' addresses, so it isn't
    /// for the general pasteboard: reading its contents other than to paste makes macOS ask the owner.
    static func hasImages(on pasteboard: NSPasteboard) -> Bool {
        if let files = fileURLs(on: pasteboard) { return files.contains(where: isImageFile) }
        return pasteboard.pasteboardItems?.contains { imageType(in: $0.types) != nil } ?? false
    }

    /// The image type an item offers ahead of any plain text, in the order its source wrote them.
    /// Copied text often comes with a picture of itself after it (a spreadsheet's cells, say), and
    /// pastes as text; a screenshot or a browser's Copy Image offers the picture alone, or first.
    static func imageType(in types: [NSPasteboard.PasteboardType]) -> NSPasteboard.PasteboardType? {
        for type in types {
            if type == .string { return nil }
            if UTType(type.rawValue)?.conforms(to: .image) == true { return type }
        }
        return nil
    }

    /// Images dragged as data, which a text view takes only when it registers for them.
    static let dragTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, .init(UTType.jpeg.identifier), .init(UTType.heic.identifier)]

    /// The image as BotChu keeps it, with the name it shows.
    static func png(from source: Source) throws -> (png: Data, name: String) {
        switch source {
        case .file(let url):
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maximumBytes else { throw ImageDelivery.Failure("Choose images smaller than 30 MB.") }
            return (try png(from: Data(contentsOf: url)), url.lastPathComponent)
        case .data(let data, let name):
            return (try png(from: data), name)
        }
    }

    static func png(from data: Data) throws -> Data {
        guard data.count <= maximumBytes, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ImageDelivery.Failure("That file couldn't be read as an image. Choose a PNG, JPEG, GIF, HEIC, or WebP image under 30 MB.")
        }
        guard png.count <= ImageAttachment.maximumBytes else { throw ImageDelivery.Failure("Images must be no larger than 5 MB after resizing.") }
        return png
    }

    private static func fileURLs(on pasteboard: NSPasteboard) -> [URL]? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.isEmpty ? nil : urls
    }

    private static func isImageFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) == true
    }
}

/// Images a sheet holds until they go with what it makes: a report, or a new task's first message.
@MainActor @Observable
final class DraftImages {
    struct Image: Identifiable {
        let id = UUID()
        let name: String
        let png: Data
        let preview: NSImage?
    }

    private(set) var images: [Image] = []
    /// Why the last images couldn't be added.
    var problem: String?

    func add(_ urls: [URL]) {
        add(urls.map(ImagePaste.Source.file))
    }

    /// Takes the images a paste or drop holds; false when it holds something else, such as text,
    /// which then pastes as usual.
    func paste(_ pasteboard: NSPasteboard) -> Bool {
        guard let sources = ImagePaste.images(on: pasteboard) else { return false }
        add(sources)
        return true
    }

    func remove(_ id: UUID) {
        images.removeAll { $0.id == id }
        problem = nil
    }

    /// Adds an image BotChu made itself, already PNG, such as a window's screenshot; its id.
    func add(png: Data, name: String) throws -> UUID {
        guard images.count < ImageAttachment.maximumCount else { throw ImageDelivery.Failure("Attach up to \(ImageAttachment.maximumCount) images.") }
        guard png.count <= ImageAttachment.maximumBytes, let preview = NSImage(data: png) else {
            throw ImageDelivery.Failure("The picture couldn't be read, or was larger than 5 MB.")
        }
        let image = Image(name: name, png: png, preview: preview)
        images.append(image)
        return image.id
    }

    private func add(_ sources: [ImagePaste.Source]) {
        problem = nil
        for source in sources {
            guard images.count < ImageAttachment.maximumCount else {
                problem = "Attach up to \(ImageAttachment.maximumCount) images."
                return
            }
            do {
                let image = try ImagePaste.png(from: source)
                images.append(Image(name: image.name, png: image.png, preview: NSImage(data: image.png)))
            } catch { problem = error.localizedDescription }
        }
    }
}
