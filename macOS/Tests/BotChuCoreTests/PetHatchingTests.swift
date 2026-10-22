import Foundation
import Testing
@testable import BotChuCore

@Suite struct PetHatchingTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-hatch-\(UUID().uuidString)")

    func write(_ text: String, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func codexJobCommandLine() {
        let job = CommandBuilder.codexJob(prompt: "draw", outputFile: "/p/run/last.txt")
        #expect(job.arguments == ["exec", "--json", "--skip-git-repo-check", "--dangerously-bypass-approvals-and-sandbox",
                                  "-o", "/p/run/last.txt", "draw"])
        #expect(job.sessionID == nil)
        #expect(CommandBuilder.codexJob(prompt: "-x", outputFile: "o", model: "gpt-5.5").arguments.suffix(3) == ["-m", "gpt-5.5", " -x"])
    }

    @Test func promptCarriesTheSettingsAndEveryExtra() {
        let prompt = PetHatching.prompt(petName: " Scout ", appearance: "A brass robot with a lantern head\n",
                                        skill: "/h/.codex-personal/skills/hatch-pet", python: "/usr/bin/python3",
                                        folder: "/w/.botchu/pet-drawing")
        #expect(prompt.contains("Pet name: Scout."))
        #expect(prompt.contains("in the owner's words: A brass robot with a lantern head\n"))
        #expect(prompt.contains("/h/.codex-personal/skills/hatch-pet/SKILL.md"))
        #expect(prompt.contains("Set PYTHON=/usr/bin/python3"))
        #expect(prompt.contains("Run folder: /w/.botchu/pet-drawing/run"))
        #expect(prompt.contains("only the nine standard rows (0-8)"))
        #expect(prompt.contains("/w/.botchu/pet-drawing/spritesheet.webp"))
        #expect(prompt.contains("--chroma-key"))
        for spec in PetActivitySpec.all {
            #expect(prompt.contains("`\(spec.id)` (alias `\(spec.alias)`, \(spec.frames) frames): \(spec.prompt)"))
        }
    }

    @Test func promptAsksForGentleMotionAndPoseReferences() {
        let prompt = PetHatching.prompt(petName: "M", appearance: "a monkey", skill: "/s", python: "/p", folder: "/w/d")
        #expect(prompt.contains("Keep every motion small and gentle"))
        #expect(prompt.contains("In `idle`, only breathing and a blink"))
        #expect(prompt.contains("No reference images."))
        #expect(prompt.contains("Also attach /w/d/run/extras/testing/decoded/running.png as the pose to match."))
        let order = PetActivitySpec.all.map(\.id)
        #expect(order.firstIndex(of: "testing")! < order.firstIndex(of: "coding")!)
        let kept = PetHatching.prompt(petName: "M", appearance: "a monkey", skill: "/s", python: "/p", folder: "/w/d",
                                      keptBase: "/w/d/kept-base.png")
        #expect(kept.contains("Keep this pet's existing look: pass /w/d/kept-base.png to prepare_pet_run.py as --reference."))
        #expect(!kept.contains("No reference images."))
    }

    @Test func redrawKeepsTheLookOnlyForTheSameAppearance() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let pet = root.appendingPathComponent("pet")
        #expect(PetHatching.baseToKeep(appearance: "a monkey", pet: pet) == nil)
        try write("png", "pet/run/references/canonical-base.png")
        // Older pets: the skill's notes start with the appearance.
        try write(#"{"pet_notes":"A sweet cuddly plush monkey. Soft cocoa-brown plush."}"#, "pet/run/pet_request.json")
        #expect(PetHatching.baseToKeep(appearance: " A sweet cuddly plush monkey. ", pet: pet)?.lastPathComponent == "canonical-base.png")
        #expect(PetHatching.baseToKeep(appearance: "A robot", pet: pet) == nil)
        // Newer pets record the appearance they were drawn from.
        try write("A robot", "pet/appearance.txt")
        #expect(PetHatching.baseToKeep(appearance: "A robot", pet: pet) != nil)
        #expect(PetHatching.baseToKeep(appearance: "A sweet cuddly plush monkey.", pet: pet) == nil)
        #expect(PetHatching.baseToKeep(appearance: "  ", pet: pet) == nil)
    }

    @Test func skillAndPythonCandidates() {
        #expect(PetHatching.skillCandidates(accountID: "codex-dev", home: "/Users/a") == [
            "/Users/a/.codex-dev/skills/hatch-pet", "/Users/a/.agents/skills/hatch-pet", "/Users/a/.codex/skills/hatch-pet"])
        #expect(PetHatching.pythonCandidates.first == "/usr/bin/python3")
    }

    @Test func progressCountsJobsAndExtras() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(PetHatching.progress(folder: root) == .init(done: 0, total: 16, current: "base"))
        // The skill's manifest, with look-direction jobs BotChu skips.
        try write(#"{"jobs":[{"id":"base","status":"complete"},{"id":"idle","status":"complete"},{"id":"waving","status":"pending"},{"id":"look-cardinals","status":"pending"},{"id":"look-row-9","status":"pending"}]}"#,
                  "run/imagegen-jobs.json")
        #expect(PetHatching.progress(folder: root) == .init(done: 2, total: 9, current: "waving"))
        try write(#"{"jobs":[{"id":"base","status":"complete"},{"id":"idle","status":"complete"}]}"#, "run/imagegen-jobs.json")
        for n in 0..<6 { try write("png", "activities/thinking/0\(n).png") }
        #expect(PetHatching.progress(folder: root) == .init(done: 3, total: 8, current: "researching"))
    }

    @Test func recordsOnlyCompleteExtras() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for n in 0..<6 { try write("png", "activities/coding/0\(n).png") }
        for n in 0..<3 { try write("png", "activities/testing/0\(n).png") }
        let manifest = try PetHatching.recordActivities(in: root)
        #expect(manifest.activities.map(\.id) == ["coding"])
        let saved = try Store.decoder.decode(PetActivitiesManifest.self, from: Data(contentsOf: root.appendingPathComponent("activities.json")))
        #expect(saved == manifest)
    }

    @Test func pruningKeepsTheReviewFiles() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["run/decoded/idle.png", "run/frames/idle/00.png", "run/final/spritesheet.png",
                     "run/references/layout-guides/idle.png", "run/qa/rows/idle.png",
                     "run/extras/coding/decoded/running.png", "run/extras/coding/frames/running/00.png",
                     "run/pet_request.json", "run/prompts/base.md", "run/references/canonical-base.png",
                     "run/qa/contact-sheet.png", "run/qa/review.json", "run/extras/coding/prompt.md",
                     "activities/coding/00.png"] {
            try write("x", path)
        }
        PetHatching.pruneRun(in: root)
        let left = FileManager.default.enumerator(atPath: root.path)!.compactMap { $0 as? String }
            .filter { !$0.hasSuffix("/") && $0.contains(".") }.sorted()
        #expect(left == ["activities/coding/00.png", "run/extras/coding/prompt.md", "run/pet_request.json",
                         "run/prompts/base.md", "run/qa/contact-sheet.png", "run/qa/review.json",
                         "run/references/canonical-base.png"])
    }

    @Test func installReplacesThePet() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BotHome(workspace: root.appendingPathComponent("bot").path)
        try write(#"{"id":"old","displayName":"Old","spritesheetPath":"spritesheet.webp"}"#, "bot/.botchu/pet/pet.json")
        try write("webp", "bot/.botchu/pet/spritesheet.webp")
        let staging = PetHatching.stagingURL(for: home)
        try write(#"{"id":"new","displayName":"New","spritesheetPath":"spritesheet.webp"}"#, "bot/.botchu/pet-drawing/pet.json")
        try write("webp", "bot/.botchu/pet-drawing/spritesheet.webp")
        try PetHatching.install(from: staging, into: home)
        #expect(home.loadPet()?.manifest.id == "new")
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }
}
