//
//  Snapshots.swift
//  Unifyr
//
//  Sendable value snapshots returned across the broker boundary. These are the
//  types the UI renders and (later) the MCP tools serialize — they must stay
//  free of EventKit/Contacts framework references and Codable-friendly so a
//  tool response is a trivial encode.
//

import Foundation

/// A calendar the user can write events to (from `EventKitBroker`).
nonisolated struct CalendarSnapshot: Identifiable, Sendable, Hashable, Codable {
    /// EventKit `calendarIdentifier`.
    let id: String
    var title: String
    var colorHex: String?
}

/// A calendar event (from `EventKitBroker`).
nonisolated struct EventSnapshot: Identifiable, Sendable, Hashable, Codable {
    /// EventKit `eventIdentifier`.
    let id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var notes: String?
    var calendarTitle: String
    /// Calendar color as a hex string (e.g. "#4A90D9") for theming; the Theme
    /// layer decides how/whether to use it.
    var calendarColorHex: String?
    /// EventKit `calendarIdentifier` of the containing calendar.
    var calendarID: String = ""
    /// Cross-device stable key (`calendarItemExternalIdentifier`) — local
    /// `eventIdentifier`s differ per device, so universal tags key on this.
    var tagKey: String = ""
}

/// A reminder (from `EventKitBroker`).
nonisolated struct ReminderSnapshot: Identifiable, Sendable, Hashable, Codable {
    /// EventKit `calendarItemIdentifier`.
    let id: String
    var title: String
    var dueDate: Date?
    var isCompleted: Bool
    /// EventKit priority 0–9 (0 = none, 1 = highest).
    var priority: Int
    var notes: String?
    var listTitle: String
    /// EventKit `calendarIdentifier` of the containing reminders list.
    var listID: String = ""
    var url: String?
    /// Location-based alarm, if any.
    var locationTitle: String?
    /// "enter" (arriving) or "leave" (leaving) when a location alarm exists.
    var locationProximity: String?
    /// Cross-device stable key (`calendarItemExternalIdentifier`) — local
    /// item identifiers differ per device, so universal tags key on this.
    var tagKey: String = ""
}

/// A photo library asset (from `PhotoBroker`). Pixels are fetched separately
/// via `PhotoBroker.thumbnail` — snapshots stay tiny.
nonisolated struct PhotoSnapshot: Identifiable, Sendable, Hashable, Codable {
    /// PhotoKit `localIdentifier`.
    let id: String
    var creationDate: Date?
    var isFavorite: Bool
    var pixelWidth: Int
    var pixelHeight: Int
}

/// A labeled value (email, phone, URL, relation, social profile, IM…). For
/// relations `label` is the relationship; for social/IM it is the service.
nonisolated struct LabeledValueSnapshot: Identifiable, Sendable, Hashable, Codable {
    var id = UUID()
    var label: String
    var value: String
}

/// A labeled postal address.
nonisolated struct PostalAddressSnapshot: Identifiable, Sendable, Hashable, Codable {
    var id = UUID()
    var label: String = "home"
    var street: String = ""
    var city: String = ""
    var state: String = ""
    var postalCode: String = ""
    var country: String = ""
}

/// A labeled date (anniversary, custom…). Birthday is its own field.
nonisolated struct ContactDateSnapshot: Identifiable, Sendable, Hashable, Codable {
    var id = UUID()
    var label: String = "anniversary"
    var date: Date = Date()
}

/// A Contacts-app group (from `ContactsBroker`).
nonisolated struct ContactGroupSnapshot: Identifiable, Sendable, Hashable, Codable {
    /// `CNGroup.identifier`.
    let id: String
    var name: String
}

/// A contact (from `ContactsBroker`).
/// Minimal contact row for index builders (name lookups, avatar stores) —
/// see ContactsBroker.fetchIndex.
nonisolated struct ContactIndexEntry: Identifiable, Sendable {
    let id: String
    let displayName: String
    let emailAddresses: [String]
    let phoneNumbers: [String]
    let thumbnail: Data?
}

nonisolated struct ContactSnapshot: Identifiable, Sendable, Hashable, Codable {
    /// `CNContact.identifier`.
    let id: String
    var givenName: String
    var familyName: String
    var organizationName: String?
    var emailAddresses: [String]
    var phoneNumbers: [String]
    /// Small thumbnail image data if the contact has one.
    var thumbnail: Data?

    // Full Apple-Contacts field set (additive; the arrays above stay for the
    // dashboard/MCP paths that only need bare strings).
    var namePrefix: String = ""
    var middleName: String = ""
    var nameSuffix: String = ""
    var nickname: String = ""
    var phoneticGivenName: String = ""
    var phoneticFamilyName: String = ""
    var jobTitle: String = ""
    var departmentName: String = ""
    var birthday: Date?
    var emails: [LabeledValueSnapshot] = []
    var phones: [LabeledValueSnapshot] = []
    var urls: [LabeledValueSnapshot] = []
    var postalAddresses: [PostalAddressSnapshot] = []
    /// label = relationship name (mother, spouse…), value = person's name.
    var relations: [LabeledValueSnapshot] = []
    /// label = service (Twitter/X, LinkedIn…), value = username.
    var socialProfiles: [LabeledValueSnapshot] = []
    /// label = service (Jabber, custom…), value = handle.
    var instantMessages: [LabeledValueSnapshot] = []
    var dates: [ContactDateSnapshot] = []

    /// Cross-device stable tagging key. CNContact identifiers differ between
    /// devices for iCloud contacts, so tags key on identity content instead:
    /// first email, else last-10 phone digits, else normalized name.
    var tagKey: String {
        if let email = emailAddresses.first?.lowercased(), !email.isEmpty {
            return "email:" + email
        }
        if let phone = phoneNumbers.first {
            let digits = phone.filter(\.isNumber)
            if digits.count >= 7 { return "phone:" + String(digits.suffix(10)) }
        }
        return "name:" + (givenName + "|" + familyName).lowercased()
    }

    /// Display name, falling back to organization, then a placeholder.
    var displayName: String {
        let full = [givenName, familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !full.isEmpty { return full }
        if let org = organizationName, !org.isEmpty { return org }
        return "No Name"
    }
}
