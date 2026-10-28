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
                native: [ModelOption(id: "recursive/flint-v1.0:free", name: "Flint (free)", efforts: [.off], provider: "openrouter")])
            #expect(picker.effectiveID == expected)
            #expect(picker.title != "Default model")
            for session in [nil, "saved-session"] {
                let invocation = CommandBuilder.invocation(kind: .pi, prompt: "Hello", model: picker.effectiveID, sessionID: session)
                let index = invocation.arguments.firstIndex(of: "--model")!
                #expect(invocation.arguments[index + 1] == expected)
            }
        }
        let inherited = ModelPickerData(kind: .pi, model: "", openRouterDefault: "recursive/flint-v1.0:free",
            native: [ModelOption(id: "recursive/flint-v1.0:free", name: "Flint (free)", efforts: [.off], provider: "openrouter")])
        #expect(inherited.title == "Flint (free)")
        #expect(inherited.selectedID.isEmpty)
        #expect(inherited.choices.first?.detail == "Flint (free)")
    }

    @Test func nativeDefaultsStayUnspecifiedAndCatalogsCannotCrossProviders() {
        // Pi and Sail inherit Settings' model (Sail's: SailCommandTests).
        for kind in AgentKind.allCases where kind != .pi && kind != .sail {
            let picker = ModelPickerData(kind: kind, model: "", openRouterDefault: "recursive/flint-v1.0:free",
                catalog: [CatalogModel(id: "other/provider", name: "Other")])
            #expect(picker.effectiveID.isEmpty)
            #expect(picker.title == "\(kind.displayName) default")
            #expect(!picker.choices.contains { $0.id == "other/provider" })
        }
    }

    @Test func sailNamesItsSettingsDefaultAndSearchesItsOwnList() {
        let catalog = [CatalogModel(id: "sail/default", name: "Sail Default", contextLength: 128000),
                       CatalogModel(id: "sail/other", name: "Other Model", contextLength: 1000000)]
        let picker = ModelPickerData(kind: .sail, model: " \n", openRouterDefault: "openrouter/model",
                                    sailDefault: " sail/default ", catalog: catalog)
        #expect(picker.selectedID.isEmpty)
        #expect(picker.effectiveID == "sail/default")
        #expect(picker.title == "Sail Default")
        #expect(picker.detail == "Default from Settings · sail/default · 128K context")
        #expect(picker.choices.first == ModelPickerData.Choice(id: "", title: "Use default from Settings", detail: "Sail Default"))
        #expect(picker.choices.map(\.id) == ["", "sail/default", "sail/other"])
        #expect(picker.matching("OTHER sail").map(\.id) == ["sail/other"])
        #expect(picker.matching("other").first?.detail == "sail/other · 1M context")
    }

    @Test func sailKeepsSelectedAndDefaultModelsWithoutDuplicates() {
        let picker = ModelPickerData(kind: .sail, model: " sail/chosen ", openRouterDefault: "openrouter/model",
                                    sailDefault: "sail/default", catalog: [
                                        CatalogModel(id: "sail/chosen", name: "Chosen Model"),
                                        CatalogModel(id: "sail/default", name: "Default Model"),
                                        CatalogModel(id: "sail/chosen", name: "Duplicate")
                                    ])
        #expect(picker.selectedID == "sail/chosen")
        #expect(picker.effectiveID == "sail/chosen")
        #expect(picker.title == "Chosen Model")
        #expect(picker.detail == "sail/chosen")
        #expect(picker.choices.map(\.id) == ["", "sail/chosen", "sail/default"])
        #expect(picker.choices.first?.detail == "Default Model")
    }

    @Test func sailWithoutACatalogKeepsCurrentAndSettingsChoices() {
        let picker = ModelPickerData(kind: .sail, model: "custom/private-model", openRouterDefault: "openrouter/model",
                                    sailDefault: "sail/default")
        #expect(picker.title == "custom/private-model")
        #expect(picker.choices.map(\.id) == ["", "custom/private-model", "sail/default"])
        #expect(picker.choices.first?.detail == "sail/default")
        #expect(picker.matching("CUSTOM private").map(\.id) == ["custom/private-model"])
        let inherited = ModelPickerData(kind: .sail, model: "", openRouterDefault: "openrouter/model", sailDefault: "sail/default")
        #expect(inherited.title == "sail/default")
        #expect(inherited.detail == "Default from Settings · sail/default")
        let unset = ModelPickerData(kind: .sail, model: "", openRouterDefault: "openrouter/model", sailDefault: " \n")
        #expect(unset.effectiveID.isEmpty)
        #expect(unset.title == "Default from Settings")
        #expect(unset.choices.map(\.id) == [""])
        #expect(unset.choices.first?.detail == "Settings ▸ Sail")
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
            native: [ModelOption(id: "recursive/flint-v1.0:free", name: "Flint (free)", efforts: [.off], provider: "openrouter"),
                     ModelOption(id: "minimax/minimax-m3.1-flash", name: "MiniMax M3.1 Flash", efforts: [.high], provider: "openrouter")])
        #expect(Set(picker.choices.map(\.id)).count == picker.choices.count)
        #expect(picker.matching("recursive FREE").map(\.id) == ["recursive/flint-v1.0:free"])
        #expect(picker.matching("minimax flash").first?.title == "MiniMax M3.1 Flash")
        #expect(picker.matching("minimax").first?.detail == "minimax/minimax-m3.1-flash")
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
