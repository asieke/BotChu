import Foundation
import Testing
@testable import BotChuCore

/// A Muse profile's own model list (#248): what `muse serve`'s `model/list` gives and how it is read.
@Suite struct MuseModelTests {
    private func result(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test func theCapturedListGivesEveryModelWithItsNameAndEfforts() throws {
        let models = try MuseModelList.parse(result(MuseModelSamples.provider))
        #expect(models.map(\.id) == ["muse-wonder-1.0", "muse-wonder-full-1.0", "muse-spark-1.3", "muse-spark-1.2"])
        // Muse labels each row with its ID; the picker spells it out.
        #expect(models.map(\.name) == ["Muse Wonder 1.0", "Muse Wonder Full 1.0", "Muse Spark 1.3", "Muse Spark 1.2"])
        #expect(models[0].efforts == [.minimal, .low, .medium, .high, .xhigh, .max])
        #expect(models[3].efforts == [.minimal, .low, .medium, .high, .xhigh])
        #expect(models.allSatisfy { !$0.moving && !$0.fast })
        // The starters are the same list, so a picker offers it before the first check too.
        #expect(GenerationOptions.models(for: .muse) == models)
    }

    @Test func theProfilesListReplacesTheStarters() throws {
        let listed = [ModelOption(id: "muse-wonder-2.0", name: "Muse Wonder 2.0", efforts: [.low, .high])]
        #expect(GenerationOptions.models(for: .muse, catalog: listed) == listed)
        #expect(GenerationOptions.models(for: .muse, catalog: []) == GenerationOptions.models(for: .muse))
        #expect(GenerationOptions.efforts(for: .muse, model: "muse-wonder-2.0", catalog: listed) == [.low, .high])
        #expect(GenerationOptions.fullName("muse-wonder-2.0", kind: .muse, catalog: listed) == "Muse Wonder 2.0")
        #expect(NativeModelList.lists(.muse) && NativeModelList.lists(.codex))
        #expect(!NativeModelList.lists(.claude) && !NativeModelList.lists(.antigravity) && NativeModelList.lists(.pi))
    }

    @Test func aBundledFallbackIsntTheAccountsList() throws {
        #expect(throws: ModelListFailure("Muse couldn’t reach its model catalog. Check its sign-in.")) {
            try MuseModelList.parse(result(MuseModelSamples.bundled))
        }
        // An open enum: a source BotChu doesn't know yet is taken as the account's.
        let models = try MuseModelList.parse(result(#"{"source":"teamCatalog","models":[{"modelId":"muse-x-1.0"}]}"#))
        #expect(models == [ModelOption(id: "muse-x-1.0", name: "Muse X 1.0", efforts: GenerationOptions.efforts(for: .muse, model: "muse-x-1.0"))])
    }

    @Test func rowsAreReadDefensively() throws {
        let models = try MuseModelList.parse(result(#"""
            {"source":"providerCatalog","models":[
             {"modelId":" muse-spark-1.3 ","displayLabel":"Spark","variants":["low","turbo","low","high"]},
             {"modelId":"muse-spark-1.3","displayLabel":"Again"},
             {"modelId":"","displayLabel":"Blank"},
             {"displayLabel":"No ID"},
             {"modelId":"muse-none-1.0","variants":[]}]}
            """#))
        // A label other than the ID is kept; unknown and repeated efforts are dropped; an empty list offers none.
        #expect(models == [ModelOption(id: "muse-spark-1.3", name: "Spark", efforts: [.low, .high]),
                           ModelOption(id: "muse-none-1.0", name: "Muse None 1.0", efforts: [])])
        #expect(throws: ModelListFailure.unrecognized("Muse")) { try MuseModelList.parse(result(#"{"source":"providerCatalog","models":[]}"#)) }
        #expect(throws: ModelListFailure.unrecognized("Muse")) { try MuseModelList.parse(result(#"{"data":[]}"#)) }
    }

    @Test func listsThroughMuseServeAndNothingElse() async throws {
        let answers = #"{"initialize": {"result": {}}, "model/list": {"result": "# + MuseModelSamples.provider + "}}"
        try await StandInModelServer.run(answers) { command, log in
            let models = try await MuseModelList.list(command: command, timeout: 10)
            #expect(models.count == 4)
            // Read-only: no session or turn, and no session log.
            let asked = StandInModelServer.methods(log)
            #expect(asked.first == "args serve --no-session-log")
            #expect(asked.dropFirst().map { String($0.split(separator: " ")[0]) } == ["initialize", "initialized", "model/list"])
            #expect(asked[3] == "model/list {}")
            // The shared scope reads a Muse profile the same way.
            let scoped = try await NativeModelList.list(ModelCatalogScope(accountID: "muse", command: command, kind: .muse), timeout: 10)
            #expect(scoped == models)
        }
        try await StandInModelServer.run(#"{"initialize": {"result": {}}}"#) { command, _ in
            await #expect(throws: ModelListFailure.unsupported("Muse")) { _ = try await MuseModelList.list(command: command, timeout: 10) }
        }
        try await StandInModelServer.run(#"{"initialize": {"result": {}}, "model/list": "hang"}"#) { command, _ in
            await #expect(throws: ModelListFailure("Muse didn’t list its models within 2 seconds.")) {
                _ = try await MuseModelList.list(command: command, timeout: 2)
            }
        }
    }
}
