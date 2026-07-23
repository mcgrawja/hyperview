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
}
