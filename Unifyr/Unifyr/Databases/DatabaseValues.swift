//
//  DatabaseValues.swift
//  Unifyr
//
//  "Unifyr 1.5: Databases" — the JSON vocabulary for the dormant §4.3 entities.
//  Everything here encodes into fields that ALREADY exist in the production
//  CloudKit schema (`DBValue.valueJSON`, `DBProperty.configJSON`,
//  `Note.schemaJSON`), so the module needs no schema deploy (D7).
//
//  All wire structs are additive-only: fields may be added, never renamed or
//  removed — the JSON is synced across devices and will be read by MCP tools.
//

import Foundation

// MARK: - Cell values

/// The decoded form of `DBValue.valueJSON`. One struct with per-kind optional
/// fields (rather than a tagged enum) so a property's kind can change without
/// destroying data: a cell keeps every field it ever had, and readers look at
/// the field for the property's CURRENT kind.
nonisolated struct DBCellValue: Codable, Equatable {
    /// text (and the title property)
    var text: String? = nil
    /// number
    var number: Double? = nil
    /// select (single element) / multiSelect (many) — ids into
    /// `DBPropertyConfig.options`
    var optionIDs: [UUID]? = nil
    /// date — "yyyy-MM-dd" (date-only in v1; human- and MCP-readable)
    var date: String? = nil
    /// checkbox
    var checked: Bool? = nil
    /// url
    var url: String? = nil
    /// person — free-form names in v1
    var people: [String]? = nil
    /// relation — target `DBRow` ids (§4.3: UUID refs, not relationships)
    var rowIDs: [UUID]? = nil

    /// True when nothing is stored — the store deletes empty `DBValue` rows.
    var isEmpty: Bool {
        (text ?? "").isEmpty
            && number == nil
            && (optionIDs ?? []).isEmpty
            && (date ?? "").isEmpty
            && (checked ?? false) == false
            && (url ?? "").isEmpty
            && (people ?? []).isEmpty
            && (rowIDs ?? []).isEmpty
    }

    // MARK: Date bridging ("yyyy-MM-dd" ⇄ Date)

    // A fixed-format civil date, NOT an ISO timestamp: "due July 21" must stay
    // July 21 on every device regardless of time zone.
    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    var dateValue: Date? {
        get { date.flatMap { Self.dateFormat.date(from: $0) } }
        set { date = newValue.map { Self.dateFormat.string(from: $0) } }
    }

    // MARK: Wire coding

    static func decode(_ data: Data) -> DBCellValue {
        (try? JSONDecoder().decode(DBCellValue.self, from: data)) ?? DBCellValue()
    }

    /// Byte-stable encoding (sorted keys) so "same value" compares equal and
    /// never dirties a synced row.
    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }
}

// MARK: - Property configuration

/// One choice of a select / multi-select property.
nonisolated struct DBSelectOption: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String = ""
    var colorHex: String = "#3E8EF7"
}

/// The decoded form of `DBProperty.configJSON`.
nonisolated struct DBPropertyConfig: Codable, Equatable {
    /// select / multiSelect choices, in display order.
    var options: [DBSelectOption]? = nil
    /// relation — the target database's `Note.id`.
    var relationTargetID: UUID? = nil
    /// The database's title property (exactly one; created with the database).
    var isTitle: Bool? = nil
    /// User-resized table column width in points (nil = the kind's default).
    /// Synced — a column you widen on the Mac is wide on the iPad.
    var width: Double? = nil

    static func decode(_ data: Data?) -> DBPropertyConfig {
        guard let data else { return DBPropertyConfig() }
        return (try? JSONDecoder().decode(DBPropertyConfig.self, from: data)) ?? DBPropertyConfig()
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }
}

// MARK: - Database-level settings

/// The decoded form of `Note.schemaJSON` on a database note — settings that
/// should follow the database across devices (unlike the table/board view
/// choice, which is a per-device preference in UserDefaults).
nonisolated struct DatabaseSettings: Codable, Equatable {
    /// Which select property the board groups by.
    var boardGroupPropertyID: UUID? = nil
    /// Saved views (Phase 4): named filter+sort slices of the database.
    var views: [DBViewConfig]? = nil

    static func decode(_ data: Data?) -> DatabaseSettings {
        guard let data else { return DatabaseSettings() }
        return (try? JSONDecoder().decode(DatabaseSettings.self, from: data)) ?? DatabaseSettings()
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }
}

// MARK: - Saved views (Phase 4)

/// One saved view: a named, filtered, sorted slice of the database, viewable
/// as a table or board, and embeddable in pages (`dbembed` blocks).
nonisolated struct DBViewConfig: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String = "View"
    /// "table" | "board" (DatabaseViewMode.rawValue).
    var mode: String = "table"
    /// AND-combined (Mail-rules style — OR views are just two views).
    var filters: [DBFilter]? = nil
    /// Applied in order (first is primary).
    var sorts: [DBSort]? = nil
    /// Board grouping override; nil falls back to the database default.
    var groupPropertyID: UUID? = nil
}

/// One filter condition on one property. Value fields are flat optionals
/// (DBCellValue-style): the op decides which one is read.
nonisolated struct DBFilter: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var propertyID: UUID? = nil
    /// See `DBFilterOp`. Stored as String for JSON stability.
    var op: String = DBFilterOp.contains.rawValue
    var text: String? = nil
    var number: Double? = nil
    var optionID: UUID? = nil
    /// "yyyy-MM-dd", like DBCellValue.date.
    var date: String? = nil

    var filterOp: DBFilterOp {
        get { DBFilterOp(rawValue: op) ?? .contains }
        set { op = newValue.rawValue }
    }
}

nonisolated enum DBFilterOp: String, Sendable, CaseIterable {
    case contains
    case notContains
    case equals
    case notEquals
    case greaterThan
    case lessThan
    case isEmpty
    case isNotEmpty
    case checked
    case unchecked
    case hasOption
    case notHasOption
    case onDate
    case beforeDate
    case afterDate

    var displayName: String {
        switch self {
        case .contains: "contains"
        case .notContains: "does not contain"
        case .equals: "is"
        case .notEquals: "is not"
        case .greaterThan: ">"
        case .lessThan: "<"
        case .isEmpty: "is empty"
        case .isNotEmpty: "is not empty"
        case .checked: "is checked"
        case .unchecked: "is unchecked"
        case .hasOption: "is"
        case .notHasOption: "is not"
        case .onDate: "is on"
        case .beforeDate: "is before"
        case .afterDate: "is after"
        }
    }

    /// Which ops make sense for a property kind (drives the op picker).
    static func valid(for kind: DBPropertyKind) -> [DBFilterOp] {
        switch kind {
        case .text, .url, .person:
            [.contains, .notContains, .equals, .isEmpty, .isNotEmpty]
        case .number:
            [.equals, .notEquals, .greaterThan, .lessThan, .isEmpty, .isNotEmpty]
        case .checkbox:
            [.checked, .unchecked]
        case .select, .multiSelect:
            [.hasOption, .notHasOption, .isEmpty, .isNotEmpty]
        case .date:
            [.onDate, .beforeDate, .afterDate, .isEmpty, .isNotEmpty]
        case .relation:
            [.isEmpty, .isNotEmpty]
        case .rollup:
            []
        }
    }

    /// Whether this op needs a value input (and which flavor comes from the
    /// property kind).
    var needsValue: Bool {
        switch self {
        case .isEmpty, .isNotEmpty, .checked, .unchecked: false
        default: true
        }
    }
}

/// One sort key.
nonisolated struct DBSort: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var propertyID: UUID? = nil
    var ascending: Bool = true
}

// MARK: - Kind presentation

extension DBPropertyKind {
    /// Kinds a user can create. `rollup` is 2.0+ (§4.3).
    static var creatable: [DBPropertyKind] {
        [.text, .number, .select, .multiSelect, .date, .checkbox, .url, .person, .relation]
    }

    /// Kinds a property can be CHANGED to. Relation needs a target database
    /// picked at creation, so type changes to it are not offered.
    static var convertible: [DBPropertyKind] {
        [.text, .number, .select, .multiSelect, .date, .checkbox, .url, .person]
    }

    var displayName: String {
        switch self {
        case .text: "Text"
        case .number: "Number"
        case .select: "Select"
        case .multiSelect: "Multi-select"
        case .date: "Date"
        case .checkbox: "Checkbox"
        case .url: "URL"
        case .person: "Person"
        case .relation: "Relation"
        case .rollup: "Rollup"
        }
    }

    var systemImage: String {
        switch self {
        case .text: "text.alignleft"
        case .number: "number"
        case .select: "chevron.down.circle"
        case .multiSelect: "tag"
        case .date: "calendar"
        case .checkbox: "checkmark.square"
        case .url: "link"
        case .person: "person"
        case .relation: "arrow.triangle.branch"
        case .rollup: "sum"
        }
    }

    /// Table column width. Fixed per kind in v1 (no per-column resizing yet).
    var columnWidth: CGFloat {
        switch self {
        case .text: 190
        case .number: 110
        case .select: 150
        case .multiSelect: 190
        case .date: 140
        case .checkbox: 84
        case .url: 190
        case .person: 160
        case .relation: 200
        case .rollup: 140
        }
    }
}

/// Serene-compliant option colors (NO green — see Theme.swift), cycled as
/// options are created.
nonisolated enum DBOptionPalette {
    static let hexes = [
        "#3E8EF7", // primary blue
        "#F2A65A", // amber
        "#8B7CF6", // violet
        "#E5624D", // coral
        "#5AB8D4", // cyan
        "#B76E9B", // mauve
        "#F5B841", // gold
        "#7F838C", // gray
    ]

    static func hex(forIndex index: Int) -> String {
        hexes[index % hexes.count]
    }
}
