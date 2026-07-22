//
//  BlockSerializer.swift
//  Unifyr
//
//  §5 / Risk #1 — the highest-risk code in the app: the mapping between a
//  TipTap/ProseMirror document and Unifyr's `[Block]` store. Built and tested
//  FIRST, in isolation from the WKWebView editor (see UnifyrTests).
//
//  Model decision (documented so it never has to be re-derived):
//    • One Block per TOP-LEVEL ProseMirror node.
//    • Lists are EXPLODED: each listItem / taskItem becomes its own Block
//      (kind .bullet / .numbered / .todo), matching the spec's per-item block
//      kinds. On assembly, consecutive same-kind list blocks regroup into one
//      list wrapper node.
//    • A block's inline children live in `content`; anything else the node type
//      carries (code `language`, image `src`, callout style) lives in `attrs`.
//      Heading level and todo `checked` are NOT stored in attrs — they live in
//      `kind` and `isChecked` respectively — so the mapping is a clean bijection
//      over the blocks Unifyr itself produces (round-trip == identity).
//
//  Known v1 flattening (acceptable, documented): a multi-paragraph blockquote or
//  a nested list collapses to a single inline run. Unifyr never emits those,
//  so its own round-trips are exact; imported exotic docs degrade gracefully.
//

import Foundation

/// The normalized, editor-agnostic content of one block. Pure value type — the
/// serializer is tested entirely at this level, no SwiftData required.
nonisolated struct BlockContent: Equatable, Sendable {
    var kind: BlockKind
    var isChecked: Bool
    var attrs: [String: PMValue]?
    var content: [PMNode]

    init(kind: BlockKind, isChecked: Bool = false, attrs: [String: PMValue]? = nil, content: [PMNode] = []) {
        self.kind = kind
        self.isChecked = isChecked
        self.attrs = attrs
        self.content = content
    }
}

/// Pure and `nonisolated` so it runs anywhere (tests, background). The three
/// methods that touch the `@MainActor` `Block` model are annotated `@MainActor`.
nonisolated enum BlockSerializer {

    // MARK: Blocks -> ProseMirror document

    static func document(from blocks: [BlockContent]) -> PMNode {
        var out: [PMNode] = []
        var i = 0
        while i < blocks.count {
            let block = blocks[i]
            if let wrapper = block.kind.listWrapperType {
                var items: [PMNode] = []
                var j = i
                while j < blocks.count, blocks[j].kind == block.kind {
                    items.append(listItemNode(for: blocks[j]))
                    j += 1
                }
                out.append(PMNode(type: wrapper, content: items))
                i = j
            } else {
                out.append(node(for: block))
                i += 1
            }
        }
        return PMNode(type: "doc", content: out)
    }

    // MARK: ProseMirror document -> Blocks

    static func blocks(from doc: PMNode) -> [BlockContent] {
        var result: [BlockContent] = []
        for node in doc.content ?? [] {
            switch node.type {
            case "paragraph":
                result.append(BlockContent(kind: .paragraph, content: node.content ?? []))

            case "heading":
                let level = node.attrs?["level"]?.intValue ?? 1
                result.append(BlockContent(kind: .heading(forLevel: level), content: node.content ?? []))

            case "bulletList":
                result.append(contentsOf: listBlocks(node, kind: .bullet))
            case "orderedList":
                result.append(contentsOf: listBlocks(node, kind: .numbered))

            case "taskList":
                for item in node.content ?? [] {
                    let checked = item.attrs?["checked"]?.boolValue ?? false
                    result.append(BlockContent(kind: .todo, isChecked: checked, content: paragraphContent(of: item)))
                }

            case "blockquote":
                result.append(BlockContent(kind: .quote, content: paragraphContent(of: node)))

            case "codeBlock":
                result.append(BlockContent(kind: .code, attrs: node.attrs, content: node.content ?? []))

            case "horizontalRule":
                result.append(BlockContent(kind: .divider))

            case "image":
                result.append(BlockContent(kind: .image, attrs: node.attrs))

            case "table":
                result.append(BlockContent(kind: .table, content: node.content ?? []))

            case "callout":
                result.append(BlockContent(kind: .callout, attrs: node.attrs, content: node.content ?? []))

            case "toggle":
                // Content is the [toggleSummary, toggleBody] pair — passed
                // through whole, like a table.
                result.append(BlockContent(kind: .toggle, attrs: node.attrs, content: node.content ?? []))

            default:
                // Unknown node: preserve its inline content as a paragraph so no
                // text is silently dropped.
                result.append(BlockContent(kind: .paragraph, content: node.content ?? []))
            }
        }
        return result
    }

    // MARK: SwiftData Block bridge

    /// Decode a stored `Block` into normalized content.
    @MainActor
    static func content(of block: Block) -> BlockContent {
        let payload = decodePayload(block.contentJSON)
        return BlockContent(
            kind: block.blockKind,
            isChecked: block.isChecked,
            attrs: payload.attrs,
            content: payload.content
        )
    }

    /// Write normalized content back into a `Block` (kind/isChecked columns +
    /// `contentJSON` payload).
    @MainActor
    static func apply(_ content: BlockContent, to block: Block) {
        // Only touch the block when something actually changed — writing (and
        // bumping modifiedAt on) every block on every save marks the whole
        // note dirty, which under CloudKit re-uploads every block record.
        let payload = encodePayload(.init(attrs: content.attrs, content: content.content))
        guard block.blockKind != content.kind
            || block.isChecked != content.isChecked
            || block.contentJSON != payload else { return }
        block.blockKind = content.kind
        block.isChecked = content.isChecked
        block.contentJSON = payload
        block.modifiedAt = Date()
    }

    /// Assemble a full document from ordered persisted blocks (Swift → JS
    /// `loadDocument`, §5).
    @MainActor
    static func document(from blocks: [Block]) -> PMNode {
        let ordered = blocks.sorted { $0.sortKey < $1.sortKey }
        return document(from: ordered.map(content(of:)))
    }

    /// Encode any node to JSON `Data` (bridge payloads, block storage).
    static func encode(_ node: PMNode) -> Data {
        (try? Self.encoder.encode(node)) ?? Data()
    }

    /// Decode a document from JSON `Data` (JS → Swift `documentChanged`, §5).
    static func decodeDocument(_ data: Data) -> PMNode {
        (try? Self.decoder.decode(PMNode.self, from: data)) ?? .emptyDocument
    }

    // MARK: - Private

    private struct BlockPayload: Codable {
        var attrs: [String: PMValue]?
        var content: [PMNode]
    }

    // sortedKeys: payload bytes must be DETERMINISTIC so "did this block
    // change?" can compare encoded payloads without false positives from
    // dictionary key order.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    private static func listItemNode(for block: BlockContent) -> PMNode {
        let paragraph = PMNode(type: "paragraph", content: block.content)
        if block.kind == .todo {
            return PMNode(
                type: "taskItem",
                attrs: ["checked": .bool(block.isChecked)],
                content: [paragraph]
            )
        }
        return PMNode(type: "listItem", content: [paragraph])
    }

    private static func node(for block: BlockContent) -> PMNode {
        switch block.kind {
        case .paragraph:
            return PMNode(type: "paragraph", content: block.content)
        case .heading1, .heading2, .heading3:
            return PMNode(type: "heading", attrs: ["level": .int(block.kind.headingLevel ?? 1)], content: block.content)
        case .quote:
            return PMNode(type: "blockquote", content: [PMNode(type: "paragraph", content: block.content)])
        case .code:
            return PMNode(type: "codeBlock", attrs: block.attrs, content: block.content)
        case .divider:
            return PMNode(type: "horizontalRule")
        case .image:
            return PMNode(type: "image", attrs: block.attrs)
        case .table:
            return PMNode(type: "table", content: block.content)
        case .callout:
            return PMNode(type: "callout", attrs: block.attrs, content: block.content)
        case .toggle:
            return PMNode(type: "toggle", attrs: block.attrs, content: block.content)
        case .bullet, .numbered, .todo:
            // Handled by the list-grouping path in `document(from:)`; a lone list
            // block still serializes sensibly as a single-item list.
            return PMNode(type: block.kind.listWrapperType ?? "bulletList", content: [listItemNode(for: block)])
        }
    }

    private static func listBlocks(_ listNode: PMNode, kind: BlockKind) -> [BlockContent] {
        (listNode.content ?? []).map { item in
            BlockContent(kind: kind, content: paragraphContent(of: item))
        }
    }

    /// The inline content of the first `paragraph` child of a container
    /// (listItem, taskItem, blockquote); `[]` if none.
    private static func paragraphContent(of container: PMNode) -> [PMNode] {
        for child in container.content ?? [] where child.type == "paragraph" {
            return child.content ?? []
        }
        return []
    }

    private static func decodePayload(_ data: Data) -> BlockPayload {
        guard !data.isEmpty else { return BlockPayload(attrs: nil, content: []) }
        return (try? decoder.decode(BlockPayload.self, from: data)) ?? BlockPayload(attrs: nil, content: [])
    }

    private static func encodePayload(_ payload: BlockPayload) -> Data {
        (try? encoder.encode(payload)) ?? Data()
    }
}

// MARK: - BlockKind mapping helpers

nonisolated extension BlockKind {
    /// The ProseMirror list wrapper this kind belongs in, if any.
    var listWrapperType: String? {
        switch self {
        case .bullet: return "bulletList"
        case .numbered: return "orderedList"
        case .todo: return "taskList"
        default: return nil
        }
    }

    /// Heading level 1–3, or nil for non-headings.
    var headingLevel: Int? {
        switch self {
        case .heading1: return 1
        case .heading2: return 2
        case .heading3: return 3
        default: return nil
        }
    }

    /// Map a ProseMirror heading level onto a block kind (clamped to 1–3).
    static func heading(forLevel level: Int) -> BlockKind {
        switch level {
        case ...1: return .heading1
        case 2: return .heading2
        default: return .heading3
        }
    }
}
