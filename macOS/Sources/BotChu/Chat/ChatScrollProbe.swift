import AppKit
import SwiftUI

/// Watches the chat's scroll view from the top of its rows (#110): tells the conversation's
/// transcript where the visible part is, in the rows' coordinates, as the reader scrolls and the
/// chat resizes, and moves the visible part to keep the reader's row in place when what is above
/// it changes height (`TranscriptViewport.correction`).
///
/// It also tells the transcript when the reader scrolls (#131), as AppKit says with its live-scroll
/// notifications for wheels, gestures and the scroller alike, and while the reader is pinned to the
/// newest content (`ChatPin`), keeps the visible part at the chat's end after anything else moved
/// or resized it: content growing, the window or the message box resizing, the scroll view settling.
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
    private var settleScheduled = false
    /// Between AppKit's start and end of a live scroll: a gesture with its momentum, or the scroller
    /// dragged. A legacy wheel's scrolls come without them.
    private var liveScrolling = false
    /// The visible part's top, in the rows' coordinates, as the reader's last scroll or the chat's
    /// last move left it: how far the reader's next scroll went counts from there.
    private var settledTop: CGFloat?

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        watch()
        report()
        keepEnd()
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
        if moved { keepEnd() }
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
        if let scroll = enclosingScrollView {
            NotificationCenter.default.addObserver(self, selector: #selector(liveScrollStarted), name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            NotificationCenter.default.addObserver(self, selector: #selector(liveScrolled), name: NSScrollView.didLiveScrollNotification, object: scroll)
            NotificationCenter.default.addObserver(self, selector: #selector(liveScrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        }
        settledTop = visible?.minY
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        clip = nil
        liveScrolling = false
    }

    /// The visible part moved or resized. Resized, a pinned chat goes back to its end at once;
    /// moved, once AppKit has said whether the reader moved it (`liveScrolled`).
    @objc private func changed(_ notification: Notification) {
        report()
        guard !correcting else { return }
        if notification.name == NSView.frameDidChangeNotification { keepEnd() } else { settleLater() }
    }

    /// The rows grew or shrank: where the reader should be is now in reach.
    @objc private func documentChanged(_ notification: Notification) {
        correctNow()
        report()
        keepEnd()
    }

    @objc private func liveScrollStarted(_ notification: Notification) { liveScrolling = true }

    /// The reader moved the visible part, by `delta` from where it was.
    @objc private func liveScrolled(_ notification: Notification) {
        guard let visible, let below, let transcript else { return }
        let delta = visible.minY - (settledTop ?? visible.minY)
        settledTop = visible.minY
        transcript.follow(.scrolled(delta: delta, below: below))
    }

    /// The reader let go: back at the end, when what they scrolled to pinned the chat.
    @objc private func liveScrollEnded(_ notification: Notification) {
        liveScrolling = false
        keepEnd()
    }

    /// Once the move that is under way has been told apart (`liveScrolled` follows the reader's
    /// own at once): a pinned chat that something else moved goes back to its end.
    private func settleLater() {
        guard !settleScheduled else { return }
        settleScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.settleScheduled = false
            self.keepEnd()
        }
    }

    /// The reader asked for the newest content: the end now, and again once the rows planned for
    /// it are laid out.
    func goToEnd() {
        liveScrolling = false
        keepEnd()
        DispatchQueue.main.async { [weak self] in self?.keepEnd() }
    }

    /// While the reader is pinned and not scrolling, the visible part goes to the end of the chat.
    func keepEnd() {
        guard !correcting, let clip, let transcript, let below, window != nil else { return }
        if transcript.keepsEnd(below: below, readerScrolling: liveScrolling) {
            correcting = true
            clip.setBoundsOrigin(Self.end(of: clip))
            enclosingScrollView?.reflectScrolledClipView(clip)
            correcting = false
            report()
        }
        settledTop = visible?.minY
    }

    /// Where the clip view's bounds start with the end of the chat at the bottom of the visible part.
    private static func end(of clip: NSClipView) -> NSPoint {
        guard let document = clip.documentView else { return clip.bounds.origin }
        var bounds = clip.bounds
        bounds.origin.y = clip.isFlipped ? document.frame.maxY : document.frame.minY - bounds.height
        return clip.constrainBoundsRect(bounds).origin
    }

    /// How far the end of the chat is below the visible part; negative past it.
    private var below: Double? {
        guard let clip, window != nil else { return nil }
        let end = Self.end(of: clip).y
        return clip.isFlipped ? end - clip.bounds.minY : clip.bounds.minY - end
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

    /// Once the chat has laid out what it planned. Tried again a few times while the rows aren't
    /// tall enough yet for the visible part to go where it should.
    func correctAfterLayout(attempt: Int = 0) {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            if !self.correctNow(settling: attempt >= 3, retrying: false) { self.correctAfterLayout(attempt: attempt + 1) }
        }
    }

    /// Moves the visible part where the transcript says the reader's row needs it. As the
    /// scroll view's rows may not have grown yet to where that is, it goes as near as it can and
    /// tries again after layout, until `settling`, when as near as it can is where it stays. True
    /// when there is nothing more to do.
    @discardableResult func correctNow(settling: Bool = false, retrying: Bool = true) -> Bool {
        guard !correcting, let clip, let transcript, let target = transcript.viewport.correction, window != nil else { return true }
        correcting = true
        let wanted = clip.convert(NSRect(x: 0, y: target, width: 1, height: clip.bounds.height), from: self)
        var bounds = clip.bounds
        bounds.origin.y = wanted.minY
        let origin = clip.constrainBoundsRect(bounds).origin
        if abs(origin.y - clip.bounds.minY) > 0.25 {
            clip.setBoundsOrigin(origin)
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
        let reached = convert(clip.bounds, from: clip).minY
        settledTop = reached
        let done = abs(reached - target) <= 0.5 || settling
        if done { transcript.corrected(to: reached) }
        correcting = false
        if done { report() } else if retrying { correctAfterLayout() }
        return done
    }
}
