import Foundation
import Testing
@testable import BotChuCore

@Suite struct ModelPickerTests {
    @Test func openRouterDisplayMatchesTheModelSentToTheCLI() {
        for (selected, fallback, expected) in [
            ("", "recursive/flint-v1.0:free", "recursive/flint-v1.0:free"),
            (" custom/model ", "recursive/flint-v1.0:free", "custom/model"),
            (" \n", " recursive/flint-v1.0:free ", "recursive/flint-v1.0:free"),
            ("", " \n", CommandBuilder.defaultOpenRouterModel),
        ] {
            let picker = ModelPickerData(kind: .pi, model: selected, openRouterDefault: fallback,
                catalog: [CatalogModel(id: "recursive/flint-v1.0:free", name: "Recursive: Flint (free)")])
            #expect(picker.effectiveID == expected)
            #expect(picker.title != "Default model")
            for session in [nil, "saved-session"] {
                let invocation = CommandBuilder.invocation(kind: .pi, prompt: "Hello", model: picker.effectiveID, sessionID: session)
                let index = invocation.arguments.firstIndex(of: "--model")!
                #expect(invocation.arguments[index + 1] == expected)
            }
        }
        let inherited = ModelPickerData(kind: .pi, model: "", openRouterDefault: "recursive/flint-v1.0:free",
            catalog: [CatalogModel(id: "recursive/flint-v1.0:free", name: "Recursive: Flint (free)")])
        #expect(inherited.title == "Flint (free)")
        #expect(inherited.selectedID.isEmpty)
        #expect(inherited.choices.first?.detail == "Flint (free)")
    }

    @Test func nativeDefaultsStayUnspecifiedAndCatalogsCannotCrossProviders() {
        for kind in AgentKind.allCases where kind != .pi {
            let picker = ModelPickerData(kind: kind, model: "", openRouterDefault: "recursive/flint-v1.0:free",
                catalog: [CatalogModel(id: "other/provider", name: "Other")])
            #expect(picker.effectiveID.isEmpty)
            #expect(picker.title == "\(kind.displayName) default")
            #expect(!picker.choices.contains { $0.id == "other/provider" })
        }
    }

    @Test func offlineCustomSelectionAndInheritedDefaultRemainReachable() {
        let picker = ModelPickerData(kind: .pi, model: "custom/private-model", openRouterDefault: "recursive/flint-v1.0:free")
        #expect(picker.title == "custom/private-model")
        #expect(picker.choices.contains { $0.id == "custom/private-model" })
        #expect(picker.choices.contains { $0.id == "recursive/flint-v1.0:free" })
        #expect(picker.matching("CUSTOM private").map(\.id) == ["custom/private-model"])
        #expect(picker.matching("not-a-model").isEmpty)
    }

    @Test func searchUsesNamesProvidersAndIDsWithoutDuplicates() {
        let picker = ModelPickerData(kind: .pi, model: "recursive/flint-v1.0:free", openRouterDefault: "recursive/flint-v1.0:free",
            catalog: [CatalogModel(id: "recursive/flint-v1.0:free", name: "Recursive: Flint (free)", contextLength: 262144),
                      CatalogModel(id: "minimax/minimax-m3.1-flash", name: "MiniMax: MiniMax M3.1 Flash", contextLength: 1000000)])
        #expect(Set(picker.choices.map(\.id)).count == picker.choices.count)
        #expect(picker.matching("recursive FREE").map(\.id) == ["recursive/flint-v1.0:free"])
        #expect(picker.matching("minimax flash").first?.title == "MiniMax M3.1 Flash")
        #expect(picker.matching("minimax").first?.detail.contains("1M context") == true)
    }

    @Test func parsesPublicCatalogAndExcludesIncompatibleOutputs() throws {
        // Public GET /api/v1/models, captured 2026-10-22; reduced to the fields the picker uses.
        let json = #"""
        {"data":[
          {"id":"recursive/flint-v1.0:free","name":"Recursive: Flint (free)","context_length":262144,
           "architecture":{"output_modalities":["text"]},"supported_parameters":["reasoning","tools"]},
          {"id":"minimax/minimax-m3.1-flash","name":"MiniMax: MiniMax M3.1 Flash","context_length":1000000,
           "architecture":{"output_modalities":["text"]},"supported_parameters":["reasoning_effort","tools"]},
          {"id":"recursive/flint-v1.0:free","name":"duplicate"},
          {"id":"image-only","name":"Image","architecture":{"output_modalities":["image"]},"supported_parameters":["tools"]},
          {"id":"no-tools","name":"Chat","supported_parameters":["temperature"]}
        ]}
        """#
        let models = try OpenRouterCatalog.parse(Data(json.utf8))
        #expect(models.map(\.id) == ["recursive/flint-v1.0:free", "minimax/minimax-m3.1-flash"])
        #expect(models[0].title == "Flint (free)")
        #expect(models[0].detail.contains("262K context"))
        #expect(throws: (any Error).self) { try OpenRouterCatalog.parse(Data(#"{"error":"unavailable"}"#.utf8)) }
        #expect(throws: (any Error).self) { try OpenRouterCatalog.parse(Data(#"{"data":[]}"#.utf8)) }
    }
}
