import AppKit
import AVFoundation
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    @Test func greetingFinishesBeforeIdleAndDoesNotReplayOnRefresh() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-wave-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("clips"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("stills"), withIntermediateDirectories: true)
        let greeting = folder.appendingPathComponent("clips/greeting.mp4")
        try await writeWaveVideo(to: greeting)
        for name in ["idle", "thinking"] {
            try FileManager.default.copyItem(at: greeting, to: folder.appendingPathComponent("clips/\(name).mp4"))
        }
        try Data().write(to: folder.appendingPathComponent("stills/idle.png"))
        let manifest = PetVideoManifest(model: "fixture", clips: [
            .init(id: "idle", still: "idle", loops: true),
            .init(id: "greeting", still: "idle", loops: false),
            .init(id: "thinking", still: "idle", loops: true),
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("video.json"))
        let package = try #require(PetVideoPackage.load(from: folder))
        let view = PetVideoLayerView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        defer { view.stop() }
        view.show(package: package, clipID: "greeting")
        try await waitForPet("greeting playing", in: view)
        view.show(package: package, clipID: "idle")
        try await Task.sleep(for: .seconds(2.5))
        #expect(view.debugState.hasPrefix("greeting "))
        try await waitForPet("idle playing", in: view, timeout: 4)

        // Active work can interrupt, but a delayed completion from that old wave cannot end a new one.
        view.show(package: package, clipID: "greeting")
        let oldItem = try #require((view.layer?.sublayers?.last as? AVPlayerLayer)?.player?.currentItem)
        view.show(package: package, clipID: "thinking")
        #expect(view.debugState.hasPrefix("thinking "))
        view.show(package: package, clipID: "greeting")
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: oldItem)
        #expect(view.debugState.hasPrefix("greeting "))
        let item = try #require((view.layer?.sublayers?.last as? AVPlayerLayer)?.player?.currentItem)
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: item)
        #expect(view.debugState.hasPrefix("idle "))
        view.show(package: package, clipID: "greeting")
        #expect(view.debugState.hasPrefix("idle "))
        let idlePlayer = try #require((view.layer?.sublayers?.last as? AVPlayerLayer)?.player)
        view.show(package: package, clipID: "idle")
        #expect((view.layer?.sublayers?.last as? AVPlayerLayer)?.player === idlePlayer)
        view.stop()
        view.show(package: package, clipID: "greeting")
        #expect(view.debugState.hasPrefix("greeting "))
    }

    /// #63: a pet never blinks out, as it did whenever a bot was selected. Until a clip has a frame
    /// (a new player draws nothing at first) its still shows; the first clip then shows at once,
    /// without fading in from nothing; a later one waits for its frame with the clip before still
    /// on screen, then fades in over it; and a clip replaced before it had a frame goes at once.
    @Test func petShowsItsStillUntilAClipHasAFrameAndNeverBlinksOut() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-pet-frames-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("clips"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("stills"), withIntermediateDirectories: true)
        let wave = folder.appendingPathComponent("clips/greeting.mp4")
        try await writeWaveVideo(to: wave)
        for name in ["idle", "thinking"] {
            try FileManager.default.copyItem(at: wave, to: folder.appendingPathComponent("clips/\(name).mp4"))
        }
        let still = NSImage(size: NSSize(width: 32, height: 32))
        still.lockFocus(); NSColor.systemGreen.setFill(); NSRect(x: 0, y: 0, width: 32, height: 32).fill(); still.unlockFocus()
        let png = try #require(still.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
        for name in ["idle", "thinking"] { try png.write(to: folder.appendingPathComponent("stills/\(name).png")) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(PetVideoManifest(model: "fixture", clips: [
            .init(id: "idle", still: "idle", loops: true),
            .init(id: "greeting", still: "idle", loops: false),
            .init(id: "thinking", still: "thinking", loops: true),
        ])).write(to: folder.appendingPathComponent("video.json"))
        let package = try #require(PetVideoPackage.load(from: folder))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = PetVideoLayerView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        defer { view.stop(); window.contentView = nil; window.close() }
        func players() -> [AVPlayerLayer] { (view.layer?.sublayers ?? []).compactMap { $0 as? AVPlayerLayer } }
        func waitUntil(_ condition: () -> Bool) async throws {
            for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
            try #require(condition())
        }

        view.show(package: package, clipID: "idle")
        #expect(view.layer?.sublayers?.first?.contents != nil)
        #expect(players().map(\.opacity) == [0])
        #expect(!view.showsCurrentClip)
        try await waitUntil { view.showsCurrentClip }
        let idle = try #require(players().last)
        #expect(idle.opacity == 1)
        #expect(idle.animation(forKey: "fade") == nil && idle.animation(forKey: "opacity") == nil)

        view.show(package: package, clipID: "thinking")
        #expect(players().map(\.opacity) == [1, 0])
        view.show(package: package, clipID: "greeting")
        #expect(players().count == 2)
        #expect(players().first === idle && idle.opacity == 1)
        try await waitUntil { view.showsCurrentClip }
        let greeting = try #require(players().last)
        #expect(greeting.opacity == 1 && greeting.animation(forKey: "fade") != nil)
        try await waitUntil { players().count == 1 }
        #expect(players().first === greeting)
    }

    /// #221: the chat's intro shows a still pet; asked to animate, as a remote queue bot's inspector
    /// asks, it plays, except with Reduce Motion, which shows the still again.
    @Test func botIntroAnimatesItsPetOnlyWhenAskedAndNeverWithReduceMotion() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-pet-intro-\(UUID().uuidString)")
        let domain = "local.BotChu.PetIntroTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        let app = AppModel(store: Store(root: root.appendingPathComponent("index")), settings: AppSettings(defaults: defaults),
                           usage: UsageCache { _, _ in throw UsageFailure("fixture") }, openRouterKey: { nil })
        defer { app.stopAll() }
        let bot = Bot(name: "Pet fixture", workspace: root.appendingPathComponent("bot").path)
        try await writePetPackage(to: root.appendingPathComponent("pet"))
        app.pets[bot.id] = try #require(PetVideoPackage.load(from: root.appendingPathComponent("pet")))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        for (animates, reduceMotion) in [(false, false), (true, false), (true, true)] {
            let host = NSHostingView(rootView: BotIntro(bot: bot, animates: animates)
                .environment(\._accessibilityReduceMotion, reduceMotion).environment(app))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            if animates && !reduceMotion {
                let pet = try #require(petViews(in: host).first)
                try await waitForPet("idle playing", in: pet)
            } else {
                #expect(petViews(in: host).isEmpty, "animates: \(animates), Reduce Motion: \(reduceMotion)")
                #expect(try drawsGreenStill(host, "pet-intro-\(animates)-\(reduceMotion)"), "animates: \(animates), Reduce Motion: \(reduceMotion)")
            }
        }
        #expect(app.runStates.isEmpty)
    }

    /// A pet with looping idle and thinking clips and a one-shot greeting, over plain green stills.
    func writePetPackage(to folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("clips"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("stills"), withIntermediateDirectories: true)
        let wave = folder.appendingPathComponent("clips/greeting.mp4")
        try await writeWaveVideo(to: wave)
        for name in ["idle", "thinking"] {
            try FileManager.default.copyItem(at: wave, to: folder.appendingPathComponent("clips/\(name).mp4"))
        }
        let still = NSImage(size: NSSize(width: 32, height: 32))
        still.lockFocus(); NSColor.systemGreen.setFill(); NSRect(x: 0, y: 0, width: 32, height: 32).fill(); still.unlockFocus()
        let png = try #require(still.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
        for name in ["idle", "thinking"] { try png.write(to: folder.appendingPathComponent("stills/\(name).png")) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(PetVideoManifest(model: "fixture", clips: [
            .init(id: "idle", still: "idle", loops: true),
            .init(id: "greeting", still: "idle", loops: false),
            .init(id: "thinking", still: "thinking", loops: true),
        ])).write(to: folder.appendingPathComponent("video.json"))
    }

    /// The pet players in a view.
    func petViews(in view: NSView) -> [PetVideoLayerView] {
        view.subviews.flatMap { ($0 as? PetVideoLayerView).map { [$0] } ?? petViews(in: $0) }
    }

    /// Whether the view draws `writePetPackage`'s green still (an emoji or a player draws none).
    func drawsGreenStill(_ view: NSView, _ name: String = "pet-still") throws -> Bool {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            let folder = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
        }
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.alphaComponent > 0.9, color.greenComponent - max(color.redComponent, color.blueComponent) > 0.25 { count += 1 }
            }
        }
        return count > 20
    }

    func waitForPet(_ prefix: String, in view: PetVideoLayerView, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if view.debugState.hasPrefix(prefix) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(view.debugState.hasPrefix(prefix), "Expected \(prefix), got \(view.debugState)")
    }

    /// A tiny, real five-second clip, with no network or committed binary fixture.
    func writeWaveVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32,
        ])
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var pixelBuffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32ARGB, nil, &pixelBuffer) == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for frame in 0..<50 {
            let deadline = Date().addingTimeInterval(3)
            while !input.isReadyForMoreMediaData, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        writer.endSession(atSourceTime: CMTime(value: 5, timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
    }
}
