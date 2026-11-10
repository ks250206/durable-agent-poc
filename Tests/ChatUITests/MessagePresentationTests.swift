import Foundation
import Testing
@testable import ChatUI

@Suite struct MessagePresentationTests {
    @Test func fencedCodeRetainsOriginalLineEndingsAndStreamingTail() {
        for payload in ["let x = 1\n", "let x = 1\r\n\r\n", "日本語 👩🏽‍💻\t\r\n", ""] {
            #expect(MessageBlock.parse("```swift\n" + payload + "```\n") == [.code(language: "swift", text: payload)])
            #expect(MessageBlock.parse("~~~unknown\r\n" + payload) == [.code(language: "unknown", text: payload)])
        }
        #expect(MessageBlock.parse("```swift\npartial 👩🏽‍💻") == [.code(language: "swift", text: "partial 👩🏽‍💻")])
        #expect(MessageBlock.parse("````text\n```\n````") == [.code(language: "text", text: "```\n")])
    }

    @Test func unsupportedBlockSyntaxRemainsVisibleAndLinksRemainRestricted() throws {
        let source = "| Unknown | table |\n| --- | --- |\n<div>literal HTML</div>\n$$ math $$"
        #expect(MessageBlock.parse(source) == [.paragraph(source)])
        for scheme in ["javascript", "file", "data", "mailto", "durablechat"] {
            #expect(!MessageLinkPolicy.allows(try #require(URL(string: scheme + ":test"))))
        }
        #expect(MessageLinkPolicy.allows(try #require(URL(string: "https://example.invalid/path"))))
    }
}
