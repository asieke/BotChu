import Foundation
import Testing
@testable import BotChuCore

@Suite struct RichMarkdownTests {
    @Test func primeSumConversationProtectsMathInListsTablesAndTotal() throws {
        let source = #"""
        I've spun up the 3 parallel subagents:

        1. [Worker 1](https://example.com/1) ($p_1 \dots p_{1000}$)
        2. Worker 2 ($p_{1001} \dots p_{2000}$)
        3. Worker 3 ($p_{2001} \dots p_{3000}$)

        | Subagent | Range | First Prime | Last Prime | Sum |
        | :--- | :--- | ---: | ---: | ---: |
        | Worker 1 | $p_1 \dots p_{1000}$ | $2$ | $7,919$ | **3,682,913** |
        | Worker 2 | $p_{1001} \dots p_{2000}$ | $7,927$ | $17,389$ | **12,591,714** |
        | Worker 3 | $p_{2001} \dots p_{3000}$ | $17,393$ | $27,449$ | **22,370,584** |
        | **Total** | **$p_1 \dots p_{3000}$** | **$2$** | **$27,449$** | **38,645,211** |

        $$3,682,913 + 12,591,714 + 22,370,584 = \mathbf{38,645,211}$$
        """#
        let html = try #require(RichMarkdown.html(source))
        #expect(html.contains("<table>") && html.contains("<ol"))
        #expect(html.contains(#"data-tex="p_1 \dots p_{1000}""#))
        #expect(html.contains(#"data-tex="7,919""#))
        #expect(html.contains(#"\mathbf{38,645,211}"#))
        #expect(html.contains("<strong>38,645,211</strong>"))
        #expect(html.contains("data-display=\"true\""))
        #expect(!html.contains("BCHUMATH"))
    }

    @Test func equationsPreserveSourceAndEscapeAttributes() throws {
        let html = try #require(RichMarkdown.html(#"\(x_i^2 + \frac{1}{\sqrt[3]{y}} \leq \alpha\) and \[\text{a < b & c}\]"#))
        #expect(html.contains(#"data-tex="x_i^2 + \frac{1}{\sqrt[3]{y}} \leq \alpha""#))
        #expect(html.contains("a &lt; b &amp; c"))
        #expect(!html.contains("BCHUMATH"))
    }

    @Test func codeCurrencyAndEscapedDollarsStayLiteral() throws {
        #expect(RichMarkdown.html(#"It costs $5 or $10. Keep \$x$ literal and `$x_1$` as code."#) == nil)
        let html = try #require(RichMarkdown.html(#"""
        Render $x_1$; code `$x_2$` and ``$x_3$ `tick` `` stay literal.

        ```tex
        $$\frac{a}{b}$$
        ```

            $indented_1$

        ~~~tex
        $unfinished_fence$
        """#))
        #expect(html.contains(#"data-tex="x_1""#))
        #expect(html.contains("<code>$x_2$</code>"))
        #expect(html.contains(#"$$\frac{a}{b}$$"#))
        #expect(html.contains("$indented_1$") && html.contains("$unfinished_fence$"))
        #expect(!html.contains("BCHUMATH"))
    }

    @Test func unsupportedMalformedAndStreamingMathKeepTheirSource() throws {
        for source in [#"$\unknown{x}$"#, "$x_{2$", "$x__2$", "$x_{", #"$$\frac{1}{"#] {
            let html = try #require(RichMarkdown.html(source))
            #expect(html.contains(source.htmlEscaped))
            #expect(!html.contains("<math"))
        }
    }

    @Test func generatedHTMLCannotExecuteModelMarkupOrLoadAssets() throws {
        let html = try #require(RichMarkdown.html(#"""
        $\text{<img src=x onerror=alert(1)>}$

        [unsafe](javascript:alert%281%29) [file](file:///tmp/test) [safe](https://example.com?q=%22)

        ```html
        <script>alert('bad')</script>
        ```
        """#))
        #expect(!html.contains("<img") && !html.contains("<script") && !html.contains("href=\"javascript:") && !html.contains("href=\"file:"))
        #expect(html.contains("href=\"https://example.com"))
        #expect(html.contains("&lt;img") && html.contains("&lt;script&gt;"))
    }

    /// A link to a file (#363) keeps the link as written, for the chat to resolve against its
    /// folder: the page never names a file itself, and a place in the reply stays text.
    @Test func fileLinksCarryTheLinkForTheChatToResolve() throws {
        let html = try #require(RichMarkdown.html(#"""
        $x$ [report](model-power-rankings-oct-2026.html), [up](../x.html), [there](file:///tmp/a.html) and [top](#top)
        """#))
        for link in ["model-power-rankings-oct-2026.html", "../x.html", "file:///tmp/a.html"] {
            let page = try #require(FileLink.pageLink(URL(string: link)!))
            #expect(html.contains("<a href=\"\(page)\">"), "\(link)")
        }
        #expect(html.components(separatedBy: "<a ").count == 4)
        #expect(!html.contains("href=\"file:") && !html.contains("href=\"model") && !html.contains("href=\"#"))
    }

    @Test func mermaidFencesBecomeDiagramsAndOtherCodeRemainsCode() throws {
        let html = try #require(RichMarkdown.html("```mermaid\nflowchart LR\n A[Chat] --> B[Bot]\n```\n\n```swift\nlet x = 1\n```"))
        #expect(html.contains("class=\"diagram-block\""))
        #expect(html.contains("flowchart LR\n A[Chat] --&gt; B[Bot]"))
        #expect(html.contains("class=\"code-block\""))
        #expect(html.contains("Copy source"))
        #expect(RichMarkdown.html("```swift\nlet x = 1\n```") == nil)
    }

    @Test func placeholdersCannotCollideWithReplyText() throws {
        let html = try #require(RichMarkdown.html("BCHUMATH0END BCHUMATHX0END and $p_{1000}$"))
        #expect(html.contains("BCHUMATH0END BCHUMATHX0END and <span"))
    }
}
