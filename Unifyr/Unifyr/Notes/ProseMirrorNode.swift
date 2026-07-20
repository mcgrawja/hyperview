//
//  ProseMirrorNode.swift
//  Unifyr
//
//  A Codable model of a TipTap/ProseMirror document node. This is the wire
//  format on both sides of the editor bridge (§5) and the substrate the
//  BlockSerializer round-trips. Kept deliberately minimal and value-typed so it
//  is testable with plain `==` and free of any editor/WebKit dependency.
//

import Foundation

/// One ProseMirror node: a block (`doc`, `paragraph`, `bulletList`, …), an
/// inline node, or a text leaf. Mirrors ProseMirror's JSON exactly.
nonisolated struct PMNode: Codable, Equatable, Sendable {
    var type: String
    var attrs: [String: PMValue]?
    var content: [PMNode]?
    var text: String?
    var marks: [PMMark]?

    init(
        type: String,
        attrs: [String: PMValue]? = nil,
        content: [PMNode]? = nil,
        text: String? = nil,
        marks: [PMMark]? = nil
    ) {
        self.type = type
        self.attrs = attrs
        self.content = content
        self.text = text
        self.marks = marks
    }
}

/// A ProseMirror mark (bold, italic, link, …).
nonisolated struct PMMark: Codable, Equatable, Sendable {
    var type: String
    var attrs: [String: PMValue]?

    init(type: String, attrs: [String: PMValue]? = nil) {
        self.type = type
        self.attrs = attrs
    }
}

/// A JSON scalar used for `attrs` values (heading level, task `checked`, code
/// `language`, image `src`, …). Only the shapes ProseMirror actually emits.
nonisolated enum PMValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported PMValue JSON scalar"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - Convenience

nonisolated extension PMNode {
    /// An empty ProseMirror document.
    static let emptyDocument = PMNode(type: "doc", content: [])

    /// A text leaf with optional marks.
    static func text(_ string: String, marks: [PMMark]? = nil) -> PMNode {
        PMNode(type: "text", text: string, marks: marks)
    }
}

nonisolated extension PMValue {
    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
