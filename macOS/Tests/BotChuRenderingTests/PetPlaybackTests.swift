import AppKit
import AVFoundation
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

    private func waitForPet(_ prefix: String, in view: PetVideoLayerView, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if view.debugState.hasPrefix(prefix) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(view.debugState.hasPrefix(prefix), "Expected \(prefix), got \(view.debugState)")
    }

    /// A tiny, real five-second clip, with no network or committed binary fixture.
    private func writeWaveVideo(to url: URL) async throws {
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
