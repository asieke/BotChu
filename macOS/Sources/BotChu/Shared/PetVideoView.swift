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

/// A still, cached, filling its frame.
struct PetStillImage: View {
    let url: URL
    private static let cache = NSCache<NSURL, NSImage>()

    var body: some View {
        if let image = Self.image(url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .accessibilityHidden(true)
        }
    }

    static func image(_ url: URL) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
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

/// Plays clips in layers: a new clip fades in over the one before, which is then let go.
final class PetVideoLayerView: NSView {
    private struct Playing {
        let clipID: String
        let player: AVQueuePlayer
        let layer: AVPlayerLayer
        var looper: AVPlayerLooper?
        var observer: NSObjectProtocol?
    }

    private var current: Playing?
    private var package: PetVideoPackage?
    /// The requested activity can still be a reaction after its player has returned to idle.
    private var requestedClipID: String?
    static let fade: CFTimeInterval = 0.35

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
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
        guard !samePackage || current?.clipID != clipID else { return }
        // Let a one-shot reaction finish before idle, including time spent loading the video.
        // A new activity or a different pet can still take over immediately.
        if samePackage, clipID == "idle", let current, package.clip(current.clipID)?.loops == false { return }
        play(clipID)
    }

    func stop() {
        if let current { release(current) }
        current = nil
        requestedClipID = nil
    }

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
        layer.opacity = 0
        var playing = Playing(clipID: clipID, player: player, layer: layer)
        if clip.loops {
            playing.looper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            player.insert(item, after: nil)
            // A reaction plays once, then idle loops.
            playing.observer = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self, weak player] _ in
                MainActor.assumeIsolated {
                    guard let self, let player, self.current?.player === player else { return }
                    self.play("idle")
                }
            }
        }
        self.layer?.addSublayer(layer)
        player.play()

        let previous = current
        current = playing
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = previous == nil ? 0 : Self.fade
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { if let previous { self?.release(previous) } }
        }
        layer.add(fade, forKey: "fade")
        layer.opacity = 1
        CATransaction.commit()
    }

    private func release(_ playing: Playing) {
        playing.player.pause()
        playing.looper?.disableLooping()
        if let observer = playing.observer { NotificationCenter.default.removeObserver(observer) }
        playing.player.removeAllItems()
        playing.layer.removeFromSuperlayer()
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
