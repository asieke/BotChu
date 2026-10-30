import AppKit
import AVFoundation
import SwiftUI
import BotChuCore

/// A pet doing what its bot is doing: the activity's clip loops (a reaction plays once, then
/// idle loops), and a change of clip cross-fades. Still shows the clip's still: for small avatars
/// that aren't the selected bot's, and with Reduce Motion.
struct PetVideoView: View {
    let package: PetVideoPackage
    let activity: BotActivity
    var animates = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clipID: String { activity.animation(among: package.available) ?? "idle" }

    var body: some View {
        if animates && !reduceMotion {
            PetVideoPlayer(package: package, clipID: clipID)
                .accessibilityHidden(true)
        } else {
            PetStillImage(url: package.stillURL(package.clip(clipID)?.still ?? "idle"))
        }
    }
}

/// A still, at its clip's size, filling its frame.
struct PetStillImage: View {
    let url: URL

    var body: some View {
        if let image = ImageThumbnails.shared.image(url, pixels: ImageThumbnails.pet) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
        }
    }
}

private struct PetVideoPlayer: NSViewRepresentable {
    let package: PetVideoPackage
    let clipID: String

    func makeNSView(context: Context) -> PetVideoLayerView {
        let view = PetVideoLayerView()
        view.show(package: package, clipID: clipID)
        return view
    }

    func updateNSView(_ view: PetVideoLayerView, context: Context) {
        view.show(package: package, clipID: clipID)
    }

    static func dismantleNSView(_ view: PetVideoLayerView, coordinator: ()) {
        view.stop()
    }
}

/// Plays clips in layers over the requested clip's still. A clip shows once its video has a
/// frame: the first at once, over the still, which is that clip's first frame; a later one fading
/// in over the clip before, which is then let go. Until then the clip before stays, or the still,
/// so the pet never blinks out while a clip loads (a fresh player draws nothing at first).
final class PetVideoLayerView: NSView {
    private final class Playing {
        let clipID: String
        let player: AVQueuePlayer
        let layer: AVPlayerLayer
        var looper: AVPlayerLooper?
        var observer: NSObjectProtocol?
        var readiness: NSKeyValueObservation?

        init(clipID: String, player: AVQueuePlayer, layer: AVPlayerLayer) {
            self.clipID = clipID
            self.player = player
            self.layer = layer
        }

        /// Stops it and takes its layer away.
        func release() {
            readiness?.invalidate()
            player.pause()
            looper?.disableLooping()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            player.removeAllItems()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeFromSuperlayer()
            CATransaction.commit()
        }
    }

    /// The clip asked for last, perhaps still loading.
    private var current: Playing?
    /// The clip on screen: `current` once it has a frame, until then the one before; nil until a
    /// clip has shown, when only the still does.
    private var shown: Playing?
    private let still = CALayer()
    private var package: PetVideoPackage?
    /// The requested activity can still be a reaction after its player has returned to idle.
    private var requestedClipID: String?
    static let fade: CFTimeInterval = 0.35

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        still.contentsGravity = .resizeAspectFill
        still.frame = bounds
        layer?.addSublayer(still)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayers?.forEach { $0.frame = bounds }
        CATransaction.commit()
    }

    func show(package: PetVideoPackage, clipID: String) {
        let samePackage = self.package?.folder == package.folder
        self.package = package
        guard !samePackage || requestedClipID != clipID else { return }
        requestedClipID = clipID
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        still.contents = ImageThumbnails.shared.image(package.stillURL(package.clip(clipID)?.still ?? "idle"), pixels: ImageThumbnails.pet)
        CATransaction.commit()
        guard !samePackage || current?.clipID != clipID else { return }
        // Let a one-shot reaction finish before idle, including time spent loading the video.
        // A new activity or a different pet can still take over immediately.
        if samePackage, clipID == "idle", let current, package.clip(current.clipID)?.loops == false { return }
        play(clipID)
    }

    func stop() {
        current?.release()
        if shown !== current { shown?.release() }
        current = nil
        shown = nil
        requestedClipID = nil
    }

    /// Whether the clip asked for last is on screen, rather than the clip before it or the still.
    var showsCurrentClip: Bool { current != nil && current === shown }

    /// The clip playing and its player's state, for review snapshots.
    var debugState: String {
        guard let current else { return "no clip" }
        let status = switch current.player.timeControlStatus {
        case .playing: "playing"
        case .paused: "paused"
        case .waitingToPlayAtSpecifiedRate: "waiting"
        @unknown default: "unknown"
        }
        let item = current.player.currentItem
        return String(format: "%@ %@ %.2fs ready=%@ error=%@", current.clipID, status, current.player.currentTime().seconds,
                      item?.status == .readyToPlay ? "yes" : "no", item?.error?.localizedDescription ?? "none")
    }

    /// The frame showing now, for review snapshots (the video layer isn't in a view's drawing).
    func currentFrame() -> CGImage? {
        guard let current, let asset = current.player.currentItem?.asset else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? generator.copyCGImage(at: current.player.currentTime(), actualTime: nil)
    }

    private func play(_ clipID: String) {
        guard let package, let clip = package.clip(clipID) else { return }
        let item = AVPlayerItem(url: package.clipURL(clipID))
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.frame = bounds
        // Hidden until it has a frame (`reveal`).
        layer.opacity = 0
        let playing = Playing(clipID: clipID, player: player, layer: layer)
        if clip.loops {
            playing.looper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            // A reaction plays once, holding its last frame until idle shows, then idle loops.
            player.actionAtItemEnd = .pause
            player.insert(item, after: nil)
            playing.observer = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self, weak player] _ in
                MainActor.assumeIsolated {
                    guard let self, let player, self.current?.player === player else { return }
                    self.play("idle")
                }
            }
        }
        // A clip replaced before it had a frame was never seen.
        if let current, current !== shown { current.release() }
        current = playing
        CATransaction.begin()
        // Without the fade a layer gets when it joins the tree.
        CATransaction.setDisableActions(true)
        self.layer?.addSublayer(layer)
        CATransaction.commit()
        player.play()
        playing.readiness = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.reveal(layer) }
            }
        }
    }

    /// Shows the current clip once its layer has a frame: at once in place of the still, or fading
    /// in over the clip on screen, which is let go when the fade ends.
    private func reveal(_ layer: AVPlayerLayer) {
        guard let current, current.layer === layer, shown !== current else { return }
        let previous = shown
        shown = current
        CATransaction.begin()
        if let previous {
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    if let self, previous === self.shown || previous === self.current { return }
                    previous.release()
                }
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = Self.fade
            layer.add(fade, forKey: "fade")
        } else {
            // Explicitly no animation: an animation with no duration takes Core Animation's default.
            CATransaction.setDisableActions(true)
        }
        layer.opacity = 1
        CATransaction.commit()
    }
}

/// How a pet is coming along, with Cancel (or Dismiss, after a failure).
struct PetJobStatus: View {
    @Environment(AppModel.self) private var model
    let botID: UUID

    var body: some View {
        if let job = model.petJobs[botID] {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if job.isActive {
                    ProgressView().controlSize(.mini)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pet: \(job.summary)")
                        Text("Started \(job.startedAt.formatted(date: .omitted, time: .shortened)); about 10 minutes in all.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("Cancel") { model.cancelPet(botID) }
                        .help("Stop waiting. Clips already started on OpenRouter still finish and are charged; the stills are kept for the next try.")
                } else {
                    Text(job.summary)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button("Dismiss") { model.dismissPet(botID) }
                }
            }
            .font(.caption)
            .controlSize(.small)
        }
    }
}
