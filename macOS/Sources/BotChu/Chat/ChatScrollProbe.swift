import AppKit
import SwiftUI

/// Watches the chat's scroll view from the top of its rows (#110): tells the conversation's
/// transcript where the visible part is, in the rows' coordinates, as the reader scrolls and the
/// chat resizes, and moves the visible part to keep the reader's row in place when what is above
/// it changes height (`TranscriptViewport.correction`).
struct ChatScrollProbe: NSViewRepresentable {
    let transcript: TranscriptModel

    func makeNSView(context: Context) -> ChatScrollProbeView {
        let view = ChatScrollProbeView()
        view.transcript = transcript
        transcript.probe = view
        return view
    }

    func updateNSView(_ view: ChatScrollProbeView, context: Context) {
        view.transcript = transcript
        transcript.probe = view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChatScrollProbeView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: 0)
    }

    static func dismantleNSView(_ view: ChatScrollProbeView, coordinator: ()) {
        view.stop()
    }
}

final class ChatScrollProbeView: NSView {
    weak var transcript: TranscriptModel?
    private weak var clip: NSClipView?
    private var scheduled = false
    private var correcting = false

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        watch()
        report()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        report()
    }

    /// The rows moved in the scroll view, as what is above them (Show earlier, the intro) changed
    /// height: the reader's row stays where it was on the screen.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let moved = abs(newOrigin.y - frame.origin.y) > 0.5
        super.setFrameOrigin(newOrigin)
        if moved, let visible, let transcript {
            transcript.hold(visibleTop: visible.minY)
            correctNow()
        }
        report()
    }

    private func watch() {
        let clip = window == nil ? nil : enclosingScrollView?.contentView
        guard clip !== self.clip else { return }
        stop()
        self.clip = clip
        guard let clip else { return }
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSView.frameDidChangeNotification, object: clip)
        if let document = clip.documentView {
            document.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(documentChanged), name: NSView.frameDidChangeNotification, object: document)
        }
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        clip = nil
    }

    @objc private func changed(_ notification: Notification) { report() }

    /// The rows grew or shrank: where the reader should be is now in reach.
    @objc private func documentChanged(_ notification: Notification) {
        correctNow()
        report()
    }

    /// The visible part, in the rows' coordinates: 0 at the top of the first row that can be
    /// scrolled to.
    private var visible: NSRect? {
        guard let clip, window != nil else { return nil }
        return convert(clip.bounds, from: clip)
    }

    func report() {
        guard !correcting, let visible, let transcript, visible.height > 0 else { return }
        transcript.scrolled(top: visible.minY, height: visible.height, width: bounds.width)
    }

    /// Once the chat has laid out what it planned.
    func correctAfterLayout() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.scheduled = false
            self?.correctNow()
        }
    }

    /// Moves the visible part where the transcript says the reader's row needs it, as near as the
    /// scroll view goes.
    func correctNow() {
        guard !correcting, let clip, let transcript, let target = transcript.viewport.correction, window != nil else { return }
        correcting = true
        let wanted = clip.convert(NSRect(x: 0, y: target, width: 1, height: clip.bounds.height), from: self)
        var bounds = clip.bounds
        bounds.origin.y = wanted.minY
        clip.setBoundsOrigin(clip.constrainBoundsRect(bounds).origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
        transcript.corrected(to: convert(clip.bounds, from: clip).minY)
        correcting = false
        report()
    }
}
