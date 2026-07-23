//
//  BlockSerializerTests.swift
//  UnifyrTests
//
//  Round-trip tests for the highest-risk code in the app (§5, Risk #1). The
//  core invariant is identity: blocks -> document -> blocks must equal the
//  original blocks, for every kind and every list-grouping boundary.
//

import Testing
import Foundation
@testable import Unifyr

struct BlockSerializerTests {

    // MARK: Phase 2 blocks (Notion refocus)

    @Test func calloutWithEmoji() {
        expectRoundTrip([
            BlockContent(
                kind: .callout,
                attrs: ["emoji": .string("⚠️")],
                content: [PMNode(type: "paragraph", content: text("mind the gap"))]
            ),
        ], "callout keeps its emoji attr and paragraphs")
    }

    @Test func toggleRoundTripsSummaryAndBody() {
        expectRoundTrip([
            BlockContent(
                kind: .toggle,
                attrs: ["open": .bool(false)],
                content: [
                    PMNode(type: "toggleSummary", content: text("Details")),
                    PMNode(type: "toggleBody", content: [
                        PMNode(type: "paragraph", content: text("hidden body")),
                        PMNode(type: "bulletList", content: [
                            PMNode(type: "listItem", content: [PMNode(type: "paragraph", content: text("nested"))]),
                        ]),
                    ]),
                ]
            ),
        ], "toggle passes summary+body through whole, fold state included")
    }

    @Test func imageWithAssetSrc() {
        expectRoundTrip([
            BlockContent(
                kind: .image,
                // width = the resize handle's px value; rides in attrs.
                attrs: ["src": .string("unifyr-asset://ABC"), "alt": .string("photo.png"), "width": .int(320)]
            ),
        ], "image keeps its asset src and resized width")
    }

    @Test func codeBlockKeepsLanguage() {
        expectRoundTrip([
            BlockContent(kind: .code, attrs: ["language": .string("swift")], content: text("let x = 1")),
        ], "code block keeps the picked language")
    }

    @Test func columnsRoundTripWholeLayout() {
        expectRoundTrip([
            BlockContent(kind: .columns, content: [
                PMNode(type: "column", content: [PMNode(type: "paragraph", content: text("left"))]),
                PMNode(type: "column", content: [
                    PMNode(type: "paragraph", content: text("right")),
                    PMNode(type: "callout", attrs: ["emoji": .string("💡")], content: [PMNode(type: "paragraph", content: text("nested"))]),
                ]),
            ]),
        ], "column layout passes its columns (and their blocks) through whole")
    }

    // MARK: Phase 3 page references

    @Test func subpageEmbedRoundTrips() {
        expectRoundTrip([
            BlockContent(
                kind: .subpage,
                attrs: ["noteID": .string("11111111-2222-3333-4444-555555555555"), "title": .string("Child"), "emoji": .null]
            ),
        ], "subpage embed keeps its target and cached label")
    }

    @Test func inlineMentionPassesThroughParagraphContent() {
        // Mentions are inline atoms INSIDE content — no serializer case needed;
        // this pins that passthrough so a refactor can't silently drop them.
        expectRoundTrip([
            BlockContent(kind: .paragraph, content: [
                .text("see "),
                PMNode(type: "pageMention", attrs: ["noteID": .string("aaaa"), "title": .string("Other page")]),
                .text(" for details"),
            ]),
        ], "inline pageMention nodes survive inside paragraph content")
    }

    @Test func refreshingPageRefsUpdatesLabelsEverywhere() {
        let id = UUID()
        let doc = PMNode(type: "doc", content: [
            PMNode(type: "subpage", attrs: ["noteID": .string(id.uuidString), "title": .string("Old title")]),
            PMNode(type: "paragraph", content: [
                PMNode(type: "pageMention", attrs: ["noteID": .string(id.uuidString), "title": .string("Old title")]),
            ]),
            PMNode(type: "paragraph", content: [
                PMNode(type: "pageMention", attrs: ["noteID": .string(UUID().uuidString), "title": .string("Gone page")]),
            ]),
        ])
        let refreshed = BlockSerializer.refreshingPageRefs(doc) { requested in
            requested == id ? (title: "New title", emoji: "🎯") : nil
        }
        #expect(refreshed.content?[0].attrs?["title"] == .string("New title"))
        #expect(refreshed.content?[0].attrs?["emoji"] == .string("🎯"))
        #expect(refreshed.content?[1].content?[0].attrs?["title"] == .string("New title"))
        // Unresolvable (trashed/deleted) refs keep their last-known label.
        #expect(refreshed.content?[2].content?[0].attrs?["title"] == .string("Gone page"))
    }

    // MARK: Helpers

    /// Inline content for a plain text run.
    private func text(_ string: String) -> [PMNode] { [.text(string)] }

    /// Assert blocks -> doc -> blocks is the identity.
    private func expectRoundTrip(
        _ blocks: [BlockContent],
        _ comment: Comment,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let doc = BlockSerializer.document(from: blocks)
        let back = BlockSerializer.blocks(from: doc)
        #expect(back == blocks, comment, sourceLocation: sourceLocation)
    }

    // MARK: Per-kind round trips

    @Test func emptyDocument() {
        expectRoundTrip([], "empty note")
        #expect(BlockSerializer.document(from: [BlockContent]()).type == "doc")
    }

    @Test func paragraph() {
        expectRoundTrip([BlockContent(kind: .paragraph, content: text("Hello world"))], "paragraph")
    }

    @Test func paragraphWithMarks() {
        let content: [PMNode] = [
            .text("bold", marks: [PMMark(type: "bold")]),
            .text(" and "),
            .text("link", marks: [PMMark(type: "link", attrs: ["href": .string("https://example.com")])]),
        ]
        expectRoundTrip([BlockContent(kind: .paragraph, content: content)], "marks survive")
    }

    @Test func headings() {
        expectRoundTrip([
            BlockContent(kind: .heading1, content: text("H1")),
            BlockContent(kind: .heading2, content: text("H2")),
            BlockContent(kind: .heading3, content: text("H3")),
        ], "heading levels map to kinds")
    }

    @Test func bulletList() {
        expectRoundTrip([
            BlockContent(kind: .bullet, content: text("one")),
            BlockContent(kind: .bullet, content: text("two")),
            BlockContent(kind: .bullet, content: text("three")),
        ], "consecutive bullets group then split back")
    }

    @Test func numberedList() {
        expectRoundTrip([
            BlockContent(kind: .numbered, content: text("first")),
            BlockContent(kind: .numbered, content: text("second")),
        ], "ordered list")
    }

    @Test func taskListChecked() {
        expectRoundTrip([
            BlockContent(kind: .todo, isChecked: false, content: text("todo")),
            BlockContent(kind: .todo, isChecked: true, content: text("done")),
        ], "task checked state survives")
    }

    @Test func quote() {
        expectRoundTrip([BlockContent(kind: .quote, content: text("a wise thing"))], "blockquote")
    }

    @Test func codeWithLanguage() {
        expectRoundTrip([
            BlockContent(kind: .code, attrs: ["language": .string("swift")], content: text("let x = 1")),
        ], "code language attr survives")
    }

    @Test func divider() {
        expectRoundTrip([BlockContent(kind: .divider)], "horizontal rule")
    }

    @Test func image() {
        expectRoundTrip([
            BlockContent(kind: .image, attrs: [
                "src": .string("asset://abc"),
                "alt": .string("a picture"),
            ]),
        ], "image attrs survive")
    }

    // MARK: List-grouping boundaries (the tricky part)

    @Test func tableWithTaskListInCell() {
        // Tables round-trip as a single .table block whose content is the raw
        // row/cell tree — including block content (a task list) inside a cell.
        let cellTask = PMNode(type: "taskList", content: [
            PMNode(type: "taskItem", attrs: ["checked": .bool(true)], content: [
                PMNode(type: "paragraph", content: text("done thing")),
            ]),
        ])
        let table = BlockContent(kind: .table, content: [
            PMNode(type: "tableRow", content: [
                PMNode(type: "tableHeader", content: [PMNode(type: "paragraph", content: text("Task"))]),
                PMNode(type: "tableHeader", content: [PMNode(type: "paragraph", content: text("Status"))]),
            ]),
            PMNode(type: "tableRow", content: [
                PMNode(type: "tableCell", content: [cellTask]),
                PMNode(type: "tableCell", content: [PMNode(type: "paragraph", content: text("ok"))]),
            ]),
        ])
        expectRoundTrip([table], "table (with nested task list) round-trips")
    }

    @Test func adjacentListsOfDifferentKindsStaySeparate() {
        expectRoundTrip([
            BlockContent(kind: .bullet, content: text("b1")),
            BlockContent(kind: .bullet, content: text("b2")),
            BlockContent(kind: .numbered, content: text("n1")),
            BlockContent(kind: .bullet, content: text("b3")),
        ], "bullet run, ordered run, bullet run — three separate wrappers")
    }

    @Test func paragraphBetweenListItemsSplitsTheList() {
        expectRoundTrip([
            BlockContent(kind: .bullet, content: text("b1")),
            BlockContent(kind: .paragraph, content: text("interruption")),
            BlockContent(kind: .bullet, content: text("b2")),
        ], "an interrupting paragraph breaks a list into two")
    }

    @Test func mixedRealisticDocument() {
        expectRoundTrip([
            BlockContent(kind: .heading1, content: text("Project Plan")),
            BlockContent(kind: .paragraph, content: text("Intro paragraph.")),
            BlockContent(kind: .todo, isChecked: true, content: text("Ship Phase 1")),
            BlockContent(kind: .todo, isChecked: false, content: text("Ship Phase 2")),
            BlockContent(kind: .heading2, content: text("Notes")),
            BlockContent(kind: .bullet, content: text("idea one")),
            BlockContent(kind: .bullet, content: text("idea two")),
            BlockContent(kind: .quote, content: text("a quote")),
            BlockContent(kind: .code, attrs: ["language": .string("json")], content: text("{}")),
            BlockContent(kind: .divider),
        ], "a full note round-trips exactly")
    }

    // MARK: JSON codec

    @Test func jsonCodecRoundTrip() {
        let blocks = [
            BlockContent(kind: .heading1, content: text("Title")),
            BlockContent(kind: .todo, isChecked: true, content: text("done")),
        ]
        let doc = BlockSerializer.document(from: blocks)
        let data = BlockSerializer.encode(doc)
        let decoded = BlockSerializer.decodeDocument(data)
        #expect(decoded == doc, "PMNode survives JSON encode/decode")
        #expect(BlockSerializer.blocks(from: decoded) == blocks, "and still round-trips to blocks")
    }

    @Test func decodeGarbageYieldsEmptyDocument() {
        let junk = Data("not json".utf8)
        #expect(BlockSerializer.decodeDocument(junk) == .emptyDocument)
    }
}
