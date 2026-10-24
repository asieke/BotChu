import AppKit
import ScreenCaptureKit
import BotChuCore

/// A picture of one of BotChu's own windows, as the window server shows it: its sidebars, chat,
/// rendered replies and pets included, and nothing of other apps' windows, BotChu's other windows
/// (sheets, menus, popovers) or the desktop. macOS lets an app capture its own windows without
/// asking for Screen Recording (ScreenCaptureKit's current-process content, macOS 14.4 and later).
enum WindowCapture {
    /// Takes a window's picture as PNG, or says why it can't. Tests and throwaway runs swap it.
    typealias Capture = @MainActor (NSWindow) async throws -> Data

    /// The window as it shows now, at most `IssueReport.screenshotEdge` pixels on its longest edge.
    static let screen: Capture = { window in
        guard #available(macOS 14.4, *) else { throw ImageDelivery.Failure("Taking it needs macOS 14.4 or later.") }
        guard window.isVisible, !window.isMiniaturized else { throw ImageDelivery.Failure("The window isn't on screen.") }
        let number = CGWindowID(window.windowNumber)
        let content = try await SCShareableContent.currentProcess
        guard let target = content.windows.first(where: { $0.windowID == number }) else {
            throw ImageDelivery.Failure("The window isn't on screen.")
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let size = IssueReport.screenshotSize(width: filter.contentRect.width, height: filter.contentRect.height,
                                              scale: Double(filter.pointPixelScale))
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let png = await Task.detached(priority: .userInitiated) {
            NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }.value
        guard let png, png.count <= ImageAttachment.maximumBytes else {
            throw ImageDelivery.Failure("The picture was larger than 5 MB.")
        }
        return png
    }

    /// Takes `window`'s picture with `capture`, giving up (and cancelling it) after `timeout`, so a
    /// capture that never finishes can't keep what asked for it waiting: the PNG, or why there is none.
    @MainActor static func take(_ window: NSWindow?, with capture: @escaping Capture, timeout: Duration = .seconds(3)) async -> Result<Data, any Error> {
        guard let window else { return .failure(ImageDelivery.Failure("BotChu couldn't find its window.")) }
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            once.tasks = [
                Task { @MainActor in
                    let result: Result<Data, any Error>
                    do { result = .success(try await capture(window)) } catch { result = .failure(error) }
                    once.finish(result)
                },
                Task { @MainActor in
                    try? await Task.sleep(for: timeout)
                    once.finish(.failure(ImageDelivery.Failure("Taking it took too long.")))
                },
            ]
        }
    }

    /// Resumes the continuation with the first result, whichever comes first, and cancels the rest.
    @MainActor private final class Once {
        private var continuation: CheckedContinuation<Result<Data, any Error>, Never>?
        var tasks: [Task<Void, Never>] = []

        init(_ continuation: CheckedContinuation<Result<Data, any Error>, Never>) {
            self.continuation = continuation
        }

        func finish(_ result: Result<Data, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            tasks.forEach { $0.cancel() }
            continuation.resume(returning: result)
        }
    }
}
