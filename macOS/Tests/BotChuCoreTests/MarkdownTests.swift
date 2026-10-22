import Foundation
import Testing
@testable import BotChuCore

@Suite struct MarkdownTests {
    @Test func paragraphsKeepInlineStylesAndHeadingsHaveLevels() {
        let blocks = MarkdownBlock.split("## Next\n\nA **bold** [link](https://example.com) and `code`.\n\nLast paragraph.")
        #expect(blocks.map(\.kind) == [.header(level: 2), .paragraph, .paragraph])
        #expect(String(blocks[0].text.characters) == "Next")
        #expect(String(blocks[1].text.characters) == "A bold link and code.")
        #expect(blocks[1].text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(blocks[1].text.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        #expect(blocks[1].text.runs.contains { $0.link == URL(string: "https://example.com") })
    }

    @Test func nestedListsAndMultilineItemsKeepTheirStructure() {
        let blocks = MarkdownBlock.split("3. First\n   continuation\n   - Child\n4. Second")
        #expect(blocks.count == 1)
        let list = blocks[0]
        #expect(list.kind == .orderedList)
        #expect(list.children.map(\.kind) == [.listItem(ordinal: 3), .listItem(ordinal: 4)])
        #expect(String(list.children[0].children[0].text.characters) == "First continuation")
        #expect(list.children[0].children[1].kind == .unorderedList)
    }

    @Test func codeFencesKeepLiteralMarkdownAndHandleStreaming() {
        let blocks = MarkdownBlock.split("Intro\n\n````swift\n  let x = \"**literal**\"\n```\n````\n\n~~~\nunclosed")
        #expect(blocks.count == 3)
        #expect(blocks[1].kind == .codeBlock(languageHint: "swift"))
        #expect(String(blocks[1].text.characters) == "  let x = \"**literal**\"\n```\n")
        #expect(blocks[2].kind == .codeBlock(languageHint: nil))
        #expect(String(blocks[2].text.characters).hasPrefix("unclosed"))
    }

    @Test func tablesPreserveCellsAlignmentAndFormatting() {
        let blocks = MarkdownBlock.split("| Worker | Sum |\n| :--- | ---: |\n| One | **3,682,913** |\n| Empty | |")
        #expect(blocks.count == 1)
        guard case .table(let columns) = blocks[0].kind else { Issue.record("Expected table"); return }
        #expect(columns.map(\.alignment) == [.left, .right])
        let rows = blocks[0].children
        #expect(rows.count == 3)
        #expect(rows[0].kind == .tableHeaderRow)
        #expect(String(rows[1].children[1].text.characters) == "3,682,913")
        #expect(rows[1].children[1].text.runs.first?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
    }

    @Test func quotesRulesAndLiteralHashes() {
        let blocks = MarkdownBlock.split("> A quote\n>\n> With a second paragraph.\n\n---\n\n#hashtag")
        #expect(blocks.map(\.kind) == [.blockQuote, .thematicBreak, .paragraph])
        #expect(blocks[0].children.count == 2)
        #expect(String(blocks[2].text.characters) == "#hashtag")
        #expect(MarkdownBlock.split("").isEmpty)
    }
}
