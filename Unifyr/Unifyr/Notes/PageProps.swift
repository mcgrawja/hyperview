//
//  PageProps.swift
//  Unifyr
//
//  The decoded form of `Note.pagePropsJSON` (Phase 5) — presentation options
//  that sync with the page. A JSON grab-bag by design (§10 risk #2): fields
//  are additive-only, and anything speculative lands here instead of in the
//  CloudKit schema.
//

import Foundation

nonisolated struct PageProps: Codable, Equatable {
    /// "color" | "gradient" | "asset" — nil = no cover.
    var coverKind: String? = nil
    var coverHex: String? = nil
    /// Second gradient stop (gradient covers).
    var coverHex2: String? = nil
    /// Cover image (asset covers) — an Asset owned by this note.
    var coverAssetID: UUID? = nil
    /// Full-width editor (default is centered column, Notion-style).
    var wideLayout: Bool? = nil

    var hasCover: Bool { coverKind != nil }

    static func decode(_ data: Data?) -> PageProps {
        guard let data else { return PageProps() }
        return (try? JSONDecoder().decode(PageProps.self, from: data)) ?? PageProps()
    }

    func encoded() -> Data? {
        // An all-nil props bag encodes as nil so untouched pages stay
        // byte-identical (and never dirty under CloudKit).
        guard self != PageProps() else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }
}

extension Note {
    var pageProps: PageProps {
        get { PageProps.decode(pagePropsJSON) }
        set {
            let encoded = newValue.encoded()
            if pagePropsJSON != encoded {
                pagePropsJSON = encoded
                modifiedAt = Date()
            }
        }
    }
}

/// Serene-compliant preset covers (no green; gradients pair a hue with a
/// softer neighbor).
nonisolated enum CoverPresets {
    static let colors = ["#3E8EF7", "#F2A65A", "#8B7CF6", "#E5624D", "#5AB8D4", "#B76E9B", "#F5B841", "#7F838C"]
    static let gradients: [(String, String)] = [
        ("#3E8EF7", "#8B7CF6"),
        ("#F2A65A", "#E5624D"),
        ("#5AB8D4", "#3E8EF7"),
        ("#B76E9B", "#8B7CF6"),
        ("#F5B841", "#F2A65A"),
        ("#7F838C", "#5AB8D4"),
    ]
}
