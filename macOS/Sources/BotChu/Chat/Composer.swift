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
    /// Whether it offers to add images (+); the Inbox's replies are text.
    var addsImages = true
    var attachmentError: String?
    /// The agents and projects chosen in the draft from `@` and `#` completion.
    var references: Binding<[MessageReference]> = .constant([])
    /// Where `@` and `#` complete from; nil leaves completion off.
    var mentions: MentionSources?
    @State private var dropTargeted = false
    @State private var completer = MentionCompleter()
    /// "Message Scout", or for a task, "Message Scout about GitChu #48".
    let placeholder: String
    let running: Bool
    /// Follow-ups reach the bot at its next tool call rather than when the turn ends.
    var midTurn = false
    let onSend: () -> Void
    let onStop: () -> Void
    @ViewBuilder let controls: Controls

    private var isEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !images.isEmpty {
                AttachmentStrip {
                    ForEach(images) { image in
                        AttachmentThumbnail(image: image, url: imageURL(image)) {
                            onRemoveImage(image.id)
                        }
                    }
                }
            }
            let unresolved = unresolvedMentions
            if let mentions, !unresolved.isEmpty {
                MentionProblems(problems: unresolved.compactMap { $0.status.problem($0.reference) },
                                projects: unresolved.contains { $0.reference.kind == .project },
                                refresh: { mentions.loadProjects() },
                                unlink: {
                                    let keys = Set(unresolved.map(\.reference.statusKey))
                                    references.wrappedValue.removeAll { keys.contains($0.statusKey) }
                                })
            }
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary).padding(.top, 4).padding(.leading, 4)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                ComposerEditor(text: $draft, focused: focused, placeholder: placeholder, send: onSend, pasteImages: onPasteImages,
                               mentions: mentions == nil ? nil : completer, mentionSources: mentions, references: references,
                               unresolvedMentions: Set(unresolved.map(\.reference.statusKey)))
            }
            if let attachmentError { Text(attachmentError).font(.caption).foregroundStyle(.red) }
            HStack(spacing: 8) {
                if addsImages { AddImagesButton(add: onAddImages) }
                controls
                if running {
                    button("stop.fill", label: "Stop", help: "Stop (⌘.)", action: onStop)
                }
                button("arrow.up", label: running ? "Queue message" : "Send", enabled: !isEmpty,
                       help: running ? (midTurn ? "Send at the bot’s next tool call" : "Queue for when this turn ends") + " (Return; Shift-Return for a new line)"
                           : "Send (Return; Shift-Return for a new line)", action: onSend)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder((focused.wrappedValue || dropTargeted) ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.15))
        }
        .takesImageDrops(isTargeted: $dropTargeted, add: onAddImages, paste: onPasteImages)
        .shadow(color: .black.opacity(0.05), radius: 12, y: 3)
        .overlay(alignment: .topLeading) {
            if mentions != nil { MentionPopupView(completer: completer, inset: 14) }
        }
    }

    /// The draft's mentions that point at nothing now, one per agent or project.
    private var unresolvedMentions: [(reference: MessageReference, status: ReferenceStatus)] {
        guard let mentions, !references.wrappedValue.isEmpty else { return [] }
        var seen = Set<String>()
        return references.wrappedValue.compactMap { reference in
            guard seen.insert(reference.statusKey).inserted else { return nil }
            let status = mentions.status(reference)
            return status.isResolved ? nil : (reference, status)
        }
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

/// A sheet's writing area that takes images as the composer does: pasted, dropped, or chosen with
/// +, shown after the text, where they go. Return starts a new line.
struct DraftEditor: View {
    @Binding var text: String
    var focused: Binding<Bool>
    let images: DraftImages
    let placeholder: String
    var editable = true
    var minHeight: CGFloat = 90
    var maxHeight: CGFloat = 220
    var identifier = "draft-input"
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary).padding(.top, 4).padding(.leading, 4)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                ComposerEditor(text: $text, focused: focused, placeholder: placeholder, send: nil, pasteImages: images.paste,
                               editable: editable, minHeight: minHeight, maxHeight: maxHeight, identifier: identifier)
            }
            if !images.images.isEmpty {
                AttachmentStrip {
                    ForEach(images.images) { image in
                        AttachmentThumbnail(name: image.name, preview: image.preview, remove: editable ? { images.remove(image.id) } : nil)
                    }
                }
            }
            if let problem = images.problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack(spacing: 4) {
                AddImagesButton(add: images.add)
                    .disabled(!editable)
                Text("Paste, drop or add images")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.5)).padding(-4).allowsHitTesting(false)
            }
        }
        .takesImageDrops(isTargeted: $dropTargeted, add: editable ? images.add : { _ in }, paste: editable ? images.paste : { _ in false })
    }
}

/// A draft's images in a row that scrolls sideways.
struct AttachmentStrip<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) { content }.padding(.top, 4)
        }.frame(height: 76)
    }
}

/// The + that chooses images from files.
struct AddImagesButton: View {
    let add: ([URL]) -> Void
    @State private var choosing = false

    var body: some View {
        Button { choosing = true } label: {
            Image(systemName: "plus").font(.system(size: 18)).frame(width: 28, height: 32)
        }
        .buttonStyle(.plain).help("Attach images").accessibilityLabel("Attach images")
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
                defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
                add(urls)
            }
        }
    }
}

extension View {
    /// Takes images dropped on the view, beside its text editor (which takes its own): image files
    /// to `add`, and images as data to `paste`.
    func takesImageDrops(isTargeted: Binding<Bool>, add: @escaping ([URL]) -> Void, paste: @escaping (NSPasteboard) -> Bool) -> some View {
        onDrop(of: [UTType.fileURL, UTType.image], isTargeted: isTargeted) { providers in
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
                            board.setData(data, forType: NSPasteboard.PasteboardType(type))
                            _ = paste(board)
                        }
                    }
                }
            }
            return !providers.isEmpty
        }
    }
}

struct AttachmentThumbnail: View {
    let name: String
    let preview: NSImage?
    var remove: (() -> Void)?

    init(name: String, preview: NSImage?, remove: (() -> Void)? = nil) {
        self.name = name
        self.preview = preview
        self.remove = remove
    }

    init(image: ImageAttachment, url: URL?, remove: (() -> Void)? = nil) {
        self.init(name: image.name, preview: url.flatMap { NSImage(contentsOf: $0) }, remove: remove)
    }

    var body: some View {
        Group {
            if let preview {
                Image(nsImage: preview).resizable().scaledToFit()
            } else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
        .frame(width: 70, height: 64)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) {
            if let remove {
                Button(action: remove) { Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.7)) }
                    .buttonStyle(.plain).accessibilityLabel("Remove \(name)")
            }
        }
        .help(name).accessibilityLabel(name)
    }
}
