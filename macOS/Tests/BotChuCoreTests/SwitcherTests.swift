import Foundation
import Testing
@testable import BotChuCore

/// #428: ⌘K's switcher searches agents, specialists and projects in one list.
struct SwitcherTests {
    let engineerBot = Bot(name: "10x Engineer Bot", emoji: "🧑‍💻", title: "Principal engineer", workspace: "/tmp/10x")
    let foxBot = Bot(name: "Product Fox", emoji: "🦊", title: "Product management", workspace: "/tmp/fox")
    let pixelBot = Bot(name: "Pixel Designer", emoji: "🎨", title: "UX/UI/Creative", workspace: "/tmp/pixel", role: .specialist)
    let botchu = ProjectCatalogEntry(name: "BotChu", repo: "asieke/BotChu", status: .active)
    let gitchu = ProjectCatalogEntry(name: "GitChu", repo: "asieke/GitChu", status: .paused)
    let pool = ProjectCatalogEntry(name: "Poolhouse", repo: "asieke/poolhouse", status: .active)

    var bots: [BotRosterEntry] { [engineerBot, foxBot, pixelBot].map { BotRosterEntry(bot: $0) } }

    func index(areas: [(bot: Bot, area: BotTask)] = []) -> SwitcherIndex {
        SwitcherIndex(bots: bots, catalog: [gitchu, botchu, pool], areas: areas.map { (BotRosterEntry(bot: $0.bot), $0.area) })
    }

    @Test func anEmptyQueryListsAgentsThenSpecialistsThenProjects() {
        let results = index().results(matching: "")
        #expect(results.map(\.kind) == [.agent, .agent, .specialist, .project, .project, .project])
        #expect(results.map(\.title) == ["10x Engineer Bot", "Product Fox", "Pixel Designer", "BotChu", "Poolhouse", "GitChu"])
        #expect(results[2].emoji == "🎨")
        #expect(results[2].place == .bot(pixelBot.id))
        #expect(index().results(matching: "", limit: 2).count == 2)
    }

    @Test func aBetterMatchComesFirstWhateverItsKind() {
        // An exact project name before a bot whose name only contains it.
        #expect(index().results(matching: "botchu").first?.place == .repo("asieke/BotChu"))
        #expect(index().results(matching: "pix").map(\.title) == ["Pixel Designer"])
        // A word's prefix: Fox, then the project's own word.
        #expect(index().results(matching: "fox").map(\.kind) == [.agent])
        #expect(index().results(matching: "chu").map(\.title) == ["BotChu", "GitChu"])
        #expect(index().results(matching: "zzz").isEmpty)
    }

    @Test func areasAreProjectsAndSayWhoseTheyAre() {
        let repoArea = BotTask(repoArea: "asieke/BotChu", checkout: "/tmp/BotChu", for: engineerBot)
        let uncatalogued = BotTask(repoArea: "asieke/garcon", checkout: "/tmp/garcon", for: engineerBot)
        let folder = BotTask(folderArea: "Taxes", folder: "/tmp/fox/areas/taxes", for: foxBot)
        let results = index(areas: [(engineerBot, repoArea), (engineerBot, uncatalogued), (foxBot, folder)]).results(matching: "")
        let projects = results.filter { $0.kind == .project }
        #expect(projects.map(\.title) == ["BotChu", "Poolhouse", "GitChu", "garcon", "Taxes"])
        #expect(projects[0].detail == "asieke/BotChu · 10x Engineer Bot")
        #expect(projects[2].detail == "asieke/GitChu")
        #expect(projects[3].place == .repo("asieke/garcon"))
        #expect(projects[4].place == .area(botID: foxBot.id, taskID: folder.id))
        #expect(projects[4].detail == "Folder · Product Fox")
        // A catalogued repository's area isn't listed twice.
        #expect(results.filter { $0.place == .repo("asieke/BotChu") }.count == 1)
    }

    @Test func theHighlightStaysWithinTheResults() {
        #expect(SwitcherHighlight.moved(0, by: 1, count: 3) == 1)
        #expect(SwitcherHighlight.moved(2, by: 1, count: 3) == 2)
        #expect(SwitcherHighlight.moved(0, by: -1, count: 3) == 0)
        #expect(SwitcherHighlight.moved(5, by: -1, count: 3) == 2)
        #expect(SwitcherHighlight.moved(0, by: 1, count: 0) == 0)
    }
}
