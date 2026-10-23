import AppKit
import ImageIO
import BotChuCore

extension AppModel {
    func imageURL(_ image: ImageAttachment, for target: ChatTarget) -> URL? {
        bot(target.botID).map { BotHome(workspace: $0.workspace).imageURL(image) }
    }

    func addImages(_ urls: [URL], to target: ChatTarget) {
        attachmentErrors[target] = nil
        for url in urls {
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 30 * 1024 * 1024 else { throw ImageDelivery.Failure("Choose images smaller than 30 MB.") }
                try addImage(Data(contentsOf: url), name: url.lastPathComponent, to: target)
            } catch { attachmentErrors[target] = error.localizedDescription }
        }
    }

    @discardableResult
    func pasteImages(_ pasteboard: NSPasteboard, to target: ChatTarget) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            addImages(urls, to: target)
            return true
        }
        guard let type = pasteboard.availableType(from: [.png, .tiff]), let data = pasteboard.data(forType: type) else { return false }
        attachmentErrors[target] = nil
        do { try addImage(data, name: "Pasted image", to: target) }
        catch { attachmentErrors[target] = error.localizedDescription }
        return true
    }

    func addImage(_ data: Data, name: String, to target: ChatTarget) throws {
        guard let bot = bot(target.botID) else { return }
        guard (draftImages[target]?.count ?? 0) < ImageAttachment.maximumCount else { throw ImageDelivery.Failure("Attach up to 8 images per message.") }
        guard data.count <= 30 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ImageDelivery.Failure("That file couldn't be read as an image. Choose a PNG, JPEG, GIF, HEIC, or WebP image under 30 MB.")
        }
        let saved = try BotHome(workspace: bot.workspace).saveImage(png, name: name)
        draftImages[target, default: []].append(saved)
    }
}
