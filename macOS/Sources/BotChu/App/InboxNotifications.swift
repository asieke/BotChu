import AppKit
import SwiftUI
import UserNotifications
import BotChuCore

/// What the Inbox's banners and Dock badge go through: the system's notification center and the
/// Dock in the app, a stand-in in tests (the notification center needs an app bundle).
@MainActor protocol BannerSystem: AnyObject {
    var isAppActive: Bool { get }
    /// Asks for alerts, sounds and badges; the system asks the owner only the first time.
    func authorize() async -> Bool
    func register(_ categories: [DeliveryBanner.Category])
    func post(_ banner: DeliveryBanner, image: URL?) async
    func setBadge(_ count: Int)
    /// Brings BotChu forward, opening its window when none is left.
    func bringForward(opening openWindow: (() -> Void)?)
    /// Hands each click on a banner to `handle`, also one that launched BotChu.
    func start(_ handle: @escaping @MainActor (DeliveryBanner.Response) -> Void)
}

/// The Inbox's notifications: a banner for each new delivery while BotChu is in the background,
/// whose buttons and Reply answer it, and the unread count on the Dock tile.
@MainActor final class InboxNotifier {
    weak var model: AppModel?
    let system: BannerSystem?
    /// Opens the main window, from a view's environment (`inboxNotifications(_:)`).
    var openWindow: (() -> Void)?
    private var categories = BannerCategories()
    /// Clicks that arrived before the deliveries were read (BotChu launched by one).
    private var waiting: [DeliveryBanner.Response] = []
    private var badge: Int?

    init(model: AppModel, system: BannerSystem?) {
        self.model = model
        self.system = system
        guard let system else { return }
        system.start { [weak self] response in self?.handle(response) }
        watchBadge()
    }

    /// A new delivery (not an update of one already shown): a banner, unless BotChu is in front.
    /// The first one asks for permission.
    func arrived(_ delivery: Delivery) {
        guard let system, let model else { return }
        let banner = DeliveryBanner(delivery: delivery, sender: model.bot(delivery.botID)?.name ?? "BotChu")
        let still = model.pets[delivery.botID]?.stillURL("idle")
        let image = still.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        Task {
            guard await system.authorize(), !system.isAppActive else { return }
            if categories.add(banner.category) { system.register(categories.all) }
            await system.post(banner, image: image)
        }
    }

    func handle(_ response: DeliveryBanner.Response) {
        guard let model, model.inbox.isLoaded else {
            waiting.append(response)
            return
        }
        guard model.inbox.delivery(response.deliveryID) != nil else { return }
        switch response.kind {
        case .reply(let text): model.inbox.reply(text, to: response.deliveryID)
        case .open: showDelivery(response.deliveryID)
        }
    }

    /// The deliveries are read: the clicks waiting for them go through.
    func inboxLoaded() {
        let waiting = waiting
        self.waiting = []
        waiting.forEach(handle)
    }

    /// Brings BotChu forward on the delivery, in the Inbox.
    func showDelivery(_ id: UUID) {
        guard let model, model.inbox.delivery(id) != nil else { return }
        system?.bringForward(opening: openWindow)
        model.showDelivery(id)
    }

    /// Keeps the Dock tile's badge on the unread count, as it changes.
    private func watchBadge() {
        guard let model, let system else { return }
        let count = withObservationTracking { model.inbox.unreadCount } onChange: { [weak self] in
            Task { @MainActor in self?.watchBadge() }
        }
        if count != badge {
            badge = count
            system.setBadge(count)
        }
    }
}

extension View {
    /// Lets a banner's click open the main window when it was closed.
    func inboxNotifications(_ model: AppModel) -> some View { modifier(InboxWindowOpener(model: model)) }
}

private struct InboxWindowOpener: ViewModifier {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { model.notifier?.openWindow = { openWindow(id: "main") } }
    }
}

/// The system's notification center and the Dock.
@MainActor final class LiveBannerSystem: NSObject, BannerSystem, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private var handle: (@MainActor (DeliveryBanner.Response) -> Void)?

    private init(center: UNUserNotificationCenter) {
        self.center = center
    }

    /// Only BotChu.app has one: the notification center traps in a process without an app bundle
    /// (`swift run`, `swift test`).
    static func make() -> LiveBannerSystem? {
        guard Bundle.main.bundlePath.hasSuffix(".app"), Bundle.main.bundleIdentifier != nil else { return nil }
        return LiveBannerSystem(center: .current())
    }

    var isAppActive: Bool { NSApp?.isActive ?? false }

    func authorize() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func register(_ categories: [DeliveryBanner.Category]) {
        center.setNotificationCategories(Set(categories.map { category in
            let choices = category.choices.enumerated().map { index, choice in
                UNNotificationAction(identifier: DeliveryBanner.Action.choice(index).identifier, title: choice, options: [])
            }
            let reply = UNTextInputNotificationAction(identifier: DeliveryBanner.Action.reply.identifier, title: "Reply", options: [],
                                                      textInputButtonTitle: "Send", textInputPlaceholder: category.replyPlaceholder)
            return UNNotificationCategory(identifier: category.identifier, actions: choices + [reply], intentIdentifiers: [])
        }))
    }

    func post(_ banner: DeliveryBanner, image: URL?) async {
        let content = UNMutableNotificationContent()
        content.title = banner.title
        content.subtitle = banner.subtitle
        content.body = banner.body
        content.categoryIdentifier = banner.category.identifier
        content.threadIdentifier = banner.botID.uuidString
        content.userInfo = banner.userInfo
        content.sound = .default
        if let image, let attachment = Self.attachment(of: image) { content.attachments = [attachment] }
        try? await center.add(UNNotificationRequest(identifier: banner.deliveryID.uuidString, content: content, trigger: nil))
    }

    /// The system moves an attachment's file into its own store, so it gets a copy of the still.
    private static func attachment(of image: URL) -> UNNotificationAttachment? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BotChu-banners", isDirectory: true)
        let copy = folder.appendingPathComponent("\(UUID().uuidString).\(image.pathExtension)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: image, to: copy)
            return try UNNotificationAttachment(identifier: "pet", url: copy)
        } catch {
            try? FileManager.default.removeItem(at: copy)
            return nil
        }
    }

    func setBadge(_ count: Int) {
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    func bringForward(opening openWindow: (() -> Void)?) {
        NSApp.activate()
        let main = NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("main") == true }
        if let window = main.first(where: { $0.isVisible || $0.isMiniaturized }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?()
        }
    }

    func start(_ handle: @escaping @MainActor (DeliveryBanner.Response) -> Void) {
        self.handle = handle
        center.delegate = self
    }

    // MARK: UNUserNotificationCenterDelegate

    /// In front, BotChu shows what arrives itself.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async {
            completionHandler(MainActor.assumeIsolated { NSApp?.isActive ?? false } ? [] : [.banner, .list, .sound])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            ? DeliveryBanner.Action.open.identifier : response.actionIdentifier
        let parsed = DeliveryBanner.response(action: action, userInfo: response.notification.request.content.userInfo,
                                             text: (response as? UNTextInputNotificationResponse)?.userText)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { if let parsed { self.handle?(parsed) } }
            completionHandler()
        }
    }
}
