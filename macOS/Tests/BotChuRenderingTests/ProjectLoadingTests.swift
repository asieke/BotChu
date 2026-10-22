import Foundation
import Testing
@testable import BotChuCore
@testable import BotChu

extension RenderingTests {
    // Run these in Release too: Swift 6.4 miscompiles tuple returns from task-group do/catch.
    @Test func projectLoadingCollectsEveryResultWithinBatchLimit() async throws {
        let fixture = try ProjectLoadingFixture()
        defer { fixture.remove() }
        let probe = ProjectLoadingProbe()
        let model = fixture.model(probe)
        await model.loadProjects()
        #expect(!model.projectsLoading)
        #expect(model.projectRecords.count == 16)
        #expect(model.projectErrors.count == 8)
        for index in 0..<24 {
            let id = "fixture/project-\(index)"
            if index.isMultiple(of: 3) { #expect(model.projectErrors[id] != nil) }
            else { #expect(model.projectRecords[id]?.text == "# Project \(index)\n") }
        }
        let state = await probe.state()
        #expect(state.active == 0)
        #expect(state.completed == 24)
        #expect(state.peak <= 4)
    }

    @Test func projectLoadingCancellationWaitsForChildrenBeforeNextLoad() async throws {
        let fixture = try ProjectLoadingFixture()
        defer { fixture.remove() }
        let probe = ProjectLoadingProbe(holdFirstBatch: true)
        let model = fixture.model(probe)
        let loading = Task { await model.loadProjects() }
        await probe.waitForFirstBatch()
        #expect(await probe.state().active == 4)
        model.destination = .providers
        loading.cancel()
        await probe.releaseFirstBatch()
        await loading.value
        let cancelled = await probe.state()
        #expect(!model.projectsLoading)
        #expect(cancelled.active == 0)
        #expect(cancelled.completed == 4)
        #expect(model.projectRecords.count + model.projectErrors.count == 4)
        await model.loadProjects()
        #expect(model.projectRecords.count + model.projectErrors.count == 24)
        #expect(await probe.state().peak <= 4)
        #expect(await probe.state().active == 0)
    }
}

@MainActor private struct ProjectLoadingFixture {
    let root: URL
    let domain: String
    let defaults: UserDefaults

    init() throws {
        domain = "botchu-project-loading-\(UUID().uuidString)"
        root = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try #require(UserDefaults(suiteName: domain))
    }

    func model(_ probe: ProjectLoadingProbe) -> AppModel {
        let model = AppModel(store: Store(root: root), settings: AppSettings(defaults: defaults),
            projectGitHub: ProjectGitHub { arguments, _ in await probe.read(arguments) })
        model.repositories = (0..<24).map { GitHubLookup.Repo(nameWithOwner: "fixture/project-\($0)", description: "", isPrivate: false) }
        model.repositoriesReadAt = .now
        return model
    }

    func remove() {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }
}

private actor ProjectLoadingProbe {
    private var active = 0, peak = 0, completed = 0
    private var holdFirstBatch: Bool
    private var held: [CheckedContinuation<Void, Never>] = []
    private var batchWaiter: CheckedContinuation<Void, Never>?

    init(holdFirstBatch: Bool = false) { self.holdFirstBatch = holdFirstBatch }

    func state() -> (active: Int, peak: Int, completed: Int) { (active, peak, completed) }

    func waitForFirstBatch() async {
        guard held.count < 4 else { return }
        await withCheckedContinuation { batchWaiter = $0 }
    }

    func releaseFirstBatch() {
        holdFirstBatch = false
        let pending = held
        held.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func read(_ arguments: [String]) async -> Shell.Result {
        active += 1
        peak = max(peak, active)
        defer { active -= 1; completed += 1 }
        // Like the existing command runner, this operation finishes after its caller cancels.
        if holdFirstBatch {
            await withCheckedContinuation { continuation in
                held.append(continuation)
                if held.count == 4 {
                    batchWaiter?.resume()
                    batchWaiter = nil
                }
            }
        } else {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { continuation.resume() }
            }
        }
        let endpoint = arguments.first { $0.hasPrefix("repos/fixture/project-") } ?? ""
        let number = endpoint.components(separatedBy: "/").dropFirst(2).first?.replacingOccurrences(of: "project-", with: "")
        guard let index = number.flatMap(Int.init), !index.isMultiple(of: 3) else {
            return Shell.Result(status: 1, output: "", errors: "Fixture failure")
        }
        let content = Data("# Project \(index)\n".utf8).base64EncodedString()
        return Shell.Result(status: 0,
            output: "{\"type\":\"file\",\"encoding\":\"base64\",\"sha\":\"sha-\(index)\",\"content\":\"\(content)\"}", errors: "")
    }
}
