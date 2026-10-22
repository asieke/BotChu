import Foundation
import Testing
@testable import BotChuCore

@Suite struct PetVideoTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-video-\(UUID().uuidString)")

    func write(_ text: String, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func everyActivityHasAClipAndEveryClipAStill() {
        let clipIDs = Set(PetVideo.clips.map(\.id))
        for activity in BotActivity.allCases {
            #expect(activity.animation(among: clipIDs) == activity.animations.first, "\(activity) has no clip of its own")
        }
        let stillIDs = Set(PetVideo.stills.map(\.id))
        #expect(PetVideo.clips.allSatisfy { stillIDs.contains($0.still) })
        // Reactions play once and return to idle, so they start and end on the idle still.
        #expect(PetVideo.clips.filter { !$0.loops }.map(\.id) == ["greeting", "done"])
        #expect(PetVideo.clips.map(\.id) == BotActivity.allCases.map(\.rawValue).sorted { a, b in
            PetVideo.clips.firstIndex { $0.id == a }! < PetVideo.clips.firstIndex { $0.id == b }!
        })
        #expect(PetVideo.clips.filter { !$0.loops }.allSatisfy { $0.still == "idle" })
        #expect(PetVideo.clips.allSatisfy { (3...15).contains($0.seconds) })
    }

    @Test func costOfAFullSet() {
        #expect(PetVideo.defaultModel.id == "bytedance/seedance-1-5-pro")
        #expect(PetVideo.defaultModel.resolution == "480p")
        #expect(abs(PetVideo.estimatedCost(PetVideo.defaultModel) - 48 * 0.0116) < 0.0001)
        #expect(PetVideo.estimatedCost(PetVideo.defaultModel) < 1)
        #expect(PetVideo.model(id: "nope") == PetVideo.defaultModel)
    }

    @Test func requestPinsTheStillAsFirstAndLastFrame() throws {
        let clip = PetVideo.clips.first { $0.id == "coding" }!
        let data = try PetVideo.requestBody(model: PetVideo.defaultModel, clip: clip, image: "data:image/jpeg;base64,AAAA")
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "bytedance/seedance-1-5-pro")
        #expect(body["duration"] as? Int == 5)
        #expect(body["resolution"] as? String == "480p")
        #expect(body["aspect_ratio"] as? String == "1:1")
        #expect(body["generate_audio"] as? Bool == false)
        let frames = try #require(body["frame_images"] as? [[String: Any]])
        #expect(frames.map { $0["frame_type"] as? String } == ["first_frame", "last_frame"])
        #expect(frames.allSatisfy { ($0["image_url"] as? [String: String])?["url"] == "data:image/jpeg;base64,AAAA" })
        let prompt = try #require(body["prompt"] as? String)
        #expect(prompt.contains("headphones stay on"))
        #expect(prompt.contains("ends in exactly the starting pose"))
    }

    @Test func parsesRealJobResponses() {
        // Captured from a real Kling 3.0 Standard job on OpenRouter.
        let submitted = #"{"id":"gen-vid-1792684868-Ni7D77XOGOWsWxOtNvDk","polling_url":"https://openrouter.ai/api/v1/videos/gen-vid-1792684868-Ni7D77XOGOWsWxOtNvDk","status":"pending"}"#
        let done = #"{"id":"gen-vid-1792684868-Ni7D77XOGOWsWxOtNvDk","generation_id":"gen-vid-1792684868-Ni7D77XOGOWsWxOtNvDk","polling_url":"https://openrouter.ai/api/v1/videos/gen-vid-1792684868-Ni7D77XOGOWsWxOtNvDk","status":"completed","unsigned_urls":["https://openrouter.ai/api/v1/videos/gen-vid-1792684868-Ni7D77XOGOWsWxOtNvDk/content?index=0"],"usage":{"cost":0.42,"is_byok":false}}"#
        let pending = PetVideo.Job.parse(Data(submitted.utf8))
        #expect(pending?.state == .pending)
        #expect(pending?.isFinished == false)
        let completed = PetVideo.Job.parse(Data(done.utf8))
        #expect(completed?.state == .completed)
        #expect(completed?.cost == 0.42)
        #expect(completed?.isFinished == true)
        let failed = PetVideo.Job.parse(Data(#"{"id":"x","status":"failed","error":"content policy"}"#.utf8))
        #expect(failed?.error == "content policy")
        // A downloaded content URL without the key answers like this.
        #expect(PetVideo.Job.errorMessage(Data(#"{"error":{"message":"No cookie auth credentials found","code":401}}"#.utf8))
                == "No cookie auth credentials found")
        #expect(PetVideo.Job.parse(Data("not json".utf8)) == nil)
    }

    @Test func onlyPassingFailuresAreRetried() {
        // The researching clip of a real pet came back "status 500: Internal Server Error".
        #expect(PetVideo.isTransient(status: 500))
        #expect(PetVideo.isTransient(status: 503))
        #expect(PetVideo.isTransient(status: 429))
        // A bad model (a real 400) or a missing key (a real 401) fails the same way every time.
        #expect(!PetVideo.isTransient(status: 400))
        #expect(!PetVideo.isTransient(status: 401))
        #expect(!PetVideo.isTransient(status: 0))
        #expect(PetVideo.retryDelays.count == 2)
    }

    @Test func stillsPromptKeepsTheCharacter() {
        let prompt = PetVideo.stillsPrompt(petName: "10x Bot", appearance: "A plush monkey\n", folder: "/w/v",
                                           reference: "/w/v/reference.png")
        #expect(prompt.contains("The attached image (/w/v/reference.png) is this character"))
        #expect(prompt.contains("load /w/v/stills/idle.png with view_image"))
        #expect(prompt.contains("copy the generated file to /w/v/stills/<id>.png"))
        for still in PetVideo.stills { #expect(prompt.contains("- `\(still.id)`: \(still.pose).")) }
        #expect(PetVideo.stillsPrompt(petName: "B", appearance: "x", folder: "/w", reference: nil).contains("There is no reference image"))
    }

    @Test func installsOnlyTheClipsThatWereMade() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BotHome(workspace: root.appendingPathComponent("bot").path)
        let staging = PetVideo.stagingURL(for: home)
        for still in ["idle", "coding"] { try write("png", ".botchu-staging/stills/\(still).png") }
        for clip in ["idle", "greeting", "coding"] { try write("mp4", ".botchu-staging/clips/\(clip).mp4") }
        try FileManager.default.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent(".botchu-staging"), to: staging)
        let manifest = try PetVideoPackage.install(from: staging, model: "kwaivgi/kling-v3.0-std", into: home)
        #expect(manifest.clips.map(\.id) == ["idle", "greeting", "coding"])
        let package = try #require(PetVideoPackage.load(from: PetVideo.folder(for: home)))
        #expect(package.available == ["idle", "greeting", "coding"])
        #expect(package.clip("greeting")?.loops == false)
        #expect(package.clip("greeting")?.still == "idle")
        #expect(BotActivity.testing.animation(among: package.available) == "coding")
        #expect(package.folder == home.petURL)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func aNewPetReplacesTheOldOne() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BotHome(workspace: root.appendingPathComponent("bot").path)
        // A sprite pet from before goes to the Trash with it.
        try write("{}", "bot/.botchu/pet/pet.json")
        let staging = PetVideo.stagingURL(for: home)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("clips"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("stills"), withIntermediateDirectories: true)
        try Data("mp4".utf8).write(to: staging.appendingPathComponent("clips/idle.mp4"))
        try Data("png".utf8).write(to: staging.appendingPathComponent("stills/idle.png"))
        _ = try PetVideoPackage.install(from: staging, model: "m", into: home)
        #expect(!FileManager.default.fileExists(atPath: home.petURL.appendingPathComponent("pet.json").path))
        #expect(PetVideoPackage.load(from: home.petURL)?.available == ["idle"])
    }

    @Test func keepsTheCharacterOnlyForTheSameAppearance() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let pet = root.appendingPathComponent("pet")
        #expect(PetVideo.characterReference(appearance: "a monkey", pet: pet) == nil)
        // A sprite pet from before video pets: its base image, matched by the skill's notes.
        try write("png", "pet/run/references/canonical-base.png")
        try write(#"{"pet_notes":"A sweet cuddly plush monkey. Soft cocoa-brown plush."}"#, "pet/run/pet_request.json")
        #expect(PetVideo.characterReference(appearance: " A sweet cuddly plush monkey. ", pet: pet)?.lastPathComponent == "canonical-base.png")
        #expect(PetVideo.characterReference(appearance: "A robot", pet: pet) == nil)
        // A pet records the appearance it was made from, and its idle still is the character.
        try write("png", "pet/stills/idle.png")
        try write("A robot", "pet/appearance.txt")
        #expect(PetVideo.characterReference(appearance: "A robot", pet: pet)?.lastPathComponent == "idle.png")
        #expect(PetVideo.characterReference(appearance: "A sweet cuddly plush monkey.", pet: pet) == nil)
        #expect(PetVideo.characterReference(appearance: "  ", pet: pet) == nil)
    }

    @Test func codexJobAttachesTheReference() {
        // `-i` takes any number of files: an option has to follow the images, or Codex reads the
        // prompt as one more image (a real run failed with "No prompt provided via stdin").
        let job = CommandBuilder.codexJob(prompt: "draw", outputFile: "/p/last.txt", model: "gpt-5.5", images: ["/p/reference.png"])
        #expect(job.arguments == ["exec", "--json", "--skip-git-repo-check", "--dangerously-bypass-approvals-and-sandbox",
                                  "-i", "/p/reference.png", "-o", "/p/last.txt", "-m", "gpt-5.5", "draw"])
        let index = job.arguments.firstIndex(of: "-i")!
        #expect(job.arguments[index + 2].hasPrefix("-"))
        #expect(CommandBuilder.codexJob(prompt: "-x", outputFile: "o").arguments.last == " -x")
    }

    @Test func noVideoPetWithoutIdle() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BotHome(workspace: root.appendingPathComponent("bot").path)
        let staging = PetVideo.stagingURL(for: home)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("clips"), withIntermediateDirectories: true)
        try Data("mp4".utf8).write(to: staging.appendingPathComponent("clips/coding.mp4"))
        #expect(throws: PetError.self) { try PetVideoPackage.install(from: staging, model: "m", into: home) }
        #expect(PetVideoPackage.load(from: PetVideo.folder(for: home)) == nil)
    }
}
