//
//  MailClipTests.swift
//  UnifyrTests
//
//  "Save to Notes" body sanitizing: plain text wins, HTML degrades to
//  readable lines, blank runs collapse, and giant digests are capped.
//

import Testing
@testable import Unifyr

struct MailClipTests {

    @Test func plainTextWinsAndBlanksCollapse() {
        let lines = MailActionsMenu.clipBodyLines(
            text: "First\r\n\r\n\r\n\r\nSecond\n\n",
            html: "<p>ignored</p>"
        )
        #expect(lines == ["First", "", "Second"])
    }

    @Test func htmlFallbackStripsTagsAndEntities() {
        let lines = MailActionsMenu.clipBodyLines(
            text: nil,
            html: "<style>.x{color:red}</style><p>Hello &amp; welcome</p><p>Line&nbsp;two<br>three &lt;ok&gt;</p>"
        )
        #expect(lines == ["Hello & welcome", "Line two", "three <ok>"])
    }

    @Test func capsRunawayBodies() {
        let huge = Array(repeating: "line", count: 500).joined(separator: "\n")
        #expect(MailActionsMenu.clipBodyLines(text: huge, html: nil).count == 120)
    }

    @Test func inlineContentLinksURLs() {
        let nodes = EditorIntegrations.inlineContent(for: "Track at https://example.com/pkg?id=1 today")
        #expect(nodes.count == 3)
        #expect(nodes[0].text == "Track at ")
        #expect(nodes[1].text == "https://example.com/pkg?id=1")
        #expect(nodes[1].marks?.first?.type == "link")
        #expect(nodes[1].marks?.first?.attrs?["href"] == .string("https://example.com/pkg?id=1"))
        #expect(nodes[2].text == " today")

        // No URL → one plain text node; empty → empty.
        #expect(EditorIntegrations.inlineContent(for: "plain words").count == 1)
        #expect(EditorIntegrations.inlineContent(for: "").isEmpty)
    }
}
