import SwiftUI
import UniformTypeIdentifiers
import BotChuCore

/// A roomy writing area that stays usable while the bot works. Stop and Send are separate actions.
struct Composer<Controls: View>: View {
    @Binding var draft: String
    var focused: Binding<Bool>
    var images: [ImageAttachment] = []
    var imageURL: (ImageAttachment) -> URL? = { _ in nil }
    var onRemoveImage: (UUID) -> Void = { _ in }
    var onAddImages: ([URL]) -> Void = { _ in }
    var onPasteImages: (NSPasteboard) -> Bool = { _ in false }
    var attachmentError: String?
    @State private var choosingImages = false
    @State private var dropTargeted = false
    /// "Message Scout", or for a task, "Message Scout about GitChu #48".
    let placeholder: String
    let running: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    @ViewBuilder let controls: Controls

    private var isEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(images) { image in
                            AttachmentThumbnail(image: image, url: imageURL(image)) {
                                onRemoveImage(image.id)
                            }
                        }
                    }.padding(.top, 4)
                }.frame(height: 76)
            }
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary).padding(.top, 4).padding(.leading, 4)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                ComposerEditor(text: $draft, focused: focused, placeholder: placeholder, send: onSend, pasteImages: onPasteImages)
            }
            if let attachmentError { Text(attachmentError).font(.caption).foregroundStyle(.red) }
            HStack(spacing: 8) {
                Button { choosingImages = true } label: {
                    Image(systemName: "plus").font(.system(size: 18)).frame(width: 28, height: 32)
                }.buttonStyle(.plain).help("Attach images").accessibilityLabel("Attach images")
                controls
                if running {
                    button("stop.fill", label: "Stop", help: "Stop (⌘.)", action: onStop)
                }
                button("arrow.up", label: running ? "Queue message" : "Send", enabled: !isEmpty,
                       help: running ? "Queue after this turn (Return; Shift-Return for a new line)"
                           : "Send (Return; Shift-Return for a new line)", action: onSend)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder((focused.wrappedValue || dropTargeted) ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.15))
        }
        .fileImporter(isPresented: $choosingImages, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
                defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
                onAddImages(urls)
            }
        }
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $dropTargeted) { providers in
            let add = onAddImages, paste = onPasteImages
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                        guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                        DispatchQueue.main.async { add([url]) }
                    }
                } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                    _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                        guard let data else { return }
                        DispatchQueue.main.async {
                            let board = NSPasteboard.withUniqueName()
                            defer { board.releaseGlobally() }
                            board.setData(data, forType: .png)
                            _ = paste(board)
                        }
                    }
                }
            }
            return !providers.isEmpty
        }
        .shadow(color: .black.opacity(0.05), radius: 12, y: 3)
    }

    private func button(_ symbol: String, label: String, enabled: Bool = true, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
                .foregroundStyle(enabled ? Color(nsColor: .controlBackgroundColor) : Color.secondary)
                .background(Circle().fill(enabled ? Color.primary : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .help(help)
    }
}


struct AttachmentThumbnail: View {
    let image: ImageAttachment
    let url: URL?
    var remove: (() -> Void)?
    var body: some View {
        Group {
            if let url, let preview = NSImage(contentsOf: url) {
                Image(nsImage: preview).resizable().scaledToFit()
            } else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
        .frame(width: 70, height: 64)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) {
            if let remove {
                Button(action: remove) { Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.7)) }
                    .buttonStyle(.plain).accessibilityLabel("Remove \(image.name)")
            }
        }
        .help(image.name).accessibilityLabel(image.name)
    }
}
