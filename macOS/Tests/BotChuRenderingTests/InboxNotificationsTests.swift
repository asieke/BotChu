import Foundation
import Testing
import BotChuCore
@testable import BotChu

/// A banner for each new delivery while BotChu is in the background, answered from its buttons, and
/// the unread count on the Dock tile, through a stand-in for the system's notification center.
extension RenderingTests {
    @Test func aNewDeliveryShowsABannerWithItsChoicesAndTheBadgeCountsIt() async throws {
        let fixture = try BannerFixture(pet: true)
        defer { fixture.cleanUp() }
        let app = fixture.app, system = fixture.system, home = ChatTarget.home(fixture.fox.id)
        #expect(system.authorizations == 0, "It asks when the first delivery arrives, not at launch")
        #expect(system.badges == [0])
        app.destination = .projects
        app.send("DELIVER", to: home)
        try await fixture.wait { !app.isRunning(home) && !system.posted.isEmpty }
        let delivery = try #require(app.inbox.all.first)

        // Sent twice with one title, it is one delivery with one banner.
        #expect(system.posted.count == 1)
        let (banner, image) = try #require(system.posted.first)
        #expect(banner.deliveryID == delivery.id && banner.title == "Fox" && banner.subtitle == "Report")
        #expect(banner.body == "Which should I file?" && banner.category.choices == ["Answer first", "Hold"])
        #expect(banner.category.replyPlaceholder == "Reply to Fox")
        #expect(system.registered.last == [banner.category])
        #expect(image == app.pets[fixture.fox.id]?.stillURL("idle") && image != nil)
        #expect(system.authorizations >= 1)
        #expect(system.badges == [0, 1])

        app.inbox.markRead(delivery.id)
        try await fixture.wait { system.badges.last == 0 }
    }

    @Test func noBannerShowsWhileBotChuIsInFront() async throws {
        let fixture = try BannerFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, system = fixture.system, home = ChatTarget.home(fixture.fox.id)
        system.isAppActive = true
        app.send("DELIVER", to: home)
        try await fixture.wait { !app.isRunning(home) && system.authorizations > 0 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(system.posted.isEmpty && system.registered.isEmpty)
        #expect(app.inbox.all.count == 1)
    }

    @Test func aChoiceRepliesWordForWordAndAClickShowsTheConversation() async throws {
        let fixture = try BannerFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, system = fixture.system, home = ChatTarget.home(fixture.fox.id)
        app.destination = .projects
        app.send("DELIVER", to: home)
        try await fixture.wait { !app.isRunning(home) && !system.posted.isEmpty }
        let (banner, _) = try #require(system.posted.first)
        let info = banner.userInfo as [AnyHashable: Any]

        system.click(try #require(DeliveryBanner.response(action: "choice.1", userInfo: info, text: nil)))
        try await fixture.wait { app.thread(home).contains { $0.text.hasPrefix("GOT-REPLY") } }
        try await fixture.wait { !app.isRunning(home) }
        let sent = try #require(app.thread(home).last { $0.role == .user })
        #expect(sent.text == "Hold" && sent.delivery == banner.deliveryID)
        #expect(app.destination == .projects, "Answering from the banner leaves BotChu as it was")

        system.click(try #require(DeliveryBanner.response(action: "open", userInfo: info, text: nil)))
        #expect(system.broughtForward == 1)
        #expect(app.destination == .inbox && app.inbox.selected == banner.deliveryID)
    }

    @Test func aReplyThatLaunchedBotChuIsSentOnceTheDeliveriesAreRead() async throws {
        let id = UUID()
        let fixture = try BannerFixture { fox in
            let delivery = Delivery(id: id, botID: fox.id, title: "Waiting", question: Delivery.Question(text: "Go?", choices: ["Go"]))
            try InboxFolder(home: BotHome(workspace: fox.workspace)).save(delivery, contents: [:])
        }
        defer { fixture.cleanUp() }
        let app = fixture.app, home = ChatTarget.home(fixture.fox.id)
        // Clicked before the deliveries are read, as when it launched BotChu.
        #expect(!app.inbox.isLoaded)
        fixture.system.click(DeliveryBanner.Response(deliveryID: id, kind: .reply("Go ahead")))
        try await fixture.wait { app.thread(home).contains { $0.text.hasPrefix("GOT-REPLY") } }
        let sent = try #require(app.thread(home).last { $0.role == .user })
        #expect(sent.text == "Go ahead" && sent.delivery == id)
    }
}

@MainActor final class StandInBanners: BannerSystem {
    var isAppActive = false
    var authorizations = 0
    var registered: [[DeliveryBanner.Category]] = []
    var posted: [(DeliveryBanner, URL?)] = []
    var badges: [Int] = []
    var broughtForward = 0
    private var handle: (@MainActor (DeliveryBanner.Response) -> Void)?

    func authorize() async -> Bool {
        authorizations += 1
        return true
    }

    func register(_ categories: [DeliveryBanner.Category]) { registered.append(categories) }
    func post(_ banner: DeliveryBanner, image: URL?) async { posted.append((banner, image)) }
    func setBadge(_ count: Int) { badges.append(count) }
    func bringForward(opening openWindow: (() -> Void)?) { broughtForward += 1 }
    func start(_ handle: @escaping @MainActor (DeliveryBanner.Response) -> Void) { self.handle = handle }

    /// The owner clicks a banner.
    func click(_ response: DeliveryBanner.Response) { handle?(response) }
}

@MainActor private final class BannerFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-banners-\(UUID().uuidString)")
    let domain = "local.BotChu.InboxNotificationsTests.\(UUID().uuidString)"
    let store: Store
    let settings: AppSettings
    let fox: Bot
    let app: AppModel
    let system = StandInBanners()

    init(pet: Bool = false, prepare: (Bot) throws -> Void = { _ in }) throws {
        store = Store(root: root.appendingPathComponent("index"))
        settings = AppSettings(defaults: UserDefaults(suiteName: domain)!)
        settings.botsRoot = root.appendingPathComponent("bots").path
        fox = Bot(name: "Fox", accountID: "codex-dev", workspace: root.appendingPathComponent("fox").path)
        let home = BotHome(workspace: fox.workspace)
        try home.save(fox)
        if pet {
            let staging = PetVideo.stagingURL(for: home)
            for sub in [PetVideo.clipsFolder, PetVideo.stillsFolder] {
                try FileManager.default.createDirectory(at: staging.appendingPathComponent(sub), withIntermediateDirectories: true)
            }
            try Data().write(to: staging.appendingPathComponent(PetVideo.clipsFolder).appendingPathComponent("idle.mp4"))
            try Data().write(to: staging.appendingPathComponent(PetVideo.stillsFolder).appendingPathComponent("idle.png"))
            _ = try PetVideoPackage.install(from: staging, model: "test", into: home, clips: PetVideo.clips.filter { $0.id == "idle" })
        }
        try prepare(fox)
        let script = root.appendingPathComponent("cli.py")
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        settings.commands[fox.accountID] = "/usr/bin/python3 \(Shell.quote(script.path))"
        try store.saveIndex([Store.Entry(id: fox.id, workspace: fox.workspace)])
        app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests") })
        // In the same main-actor turn as the model's start, so before its deliveries are read.
        app.notifier = InboxNotifier(model: app, system: system)
    }

    func wait(seconds: Int = 30, _ condition: () -> Bool) async throws {
        for _ in 0..<(seconds * 40) {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Timed out: \(app.thread(.home(fox.id)).map(\.text))")
        throw CocoaError(.executableLoad)
    }

    func cleanUp() {
        app.stopAll()
        UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }

    static let script = #"""
    import json, re, subprocess, sys
    def emit(value): print(json.dumps(value), flush=True)
    prompt = sys.argv[-1]
    emit({"type":"thread.started", "thread_id":"fixture-session"})
    brief = prompt.splitlines()[-1]
    reply = re.search(r"\[Your owner's reply from the Inbox to your delivery “[^”]*” \(([0-9a-f-]+)\)\]", prompt)
    if reply:
        answer = "GOT-REPLY " + reply.group(1) + " " + brief
    elif brief == "DELIVER":
        for note in ["First version", "Second version"]:
            subprocess.run(["botchu-inbox", "send", "--title", "Report", "--note", note,
                            "--ask", "Which should I file?", "--choice", "Answer first", "--choice", "Hold"])
        answer = "Sent"
    else:
        answer = "Done"
    emit({"type":"item.completed", "item":{"type":"agent_message", "text":answer}})
    emit({"type":"turn.completed"})
    """#
}
