//
//  MailFilters.swift
//  Hyperview
//
//  The shared condition system behind Smart Mailboxes (saved searches) and
//  Rules (conditions → actions on incoming mail). Conditions/actions are
//  Codable and stored as JSON blobs on their @Models — the spec's preferred
//  shape for evolvable data (§10 risk 2): new fields decode with defaults, no
//  store migration needed.
//

import Foundation
import SwiftData
import SwiftUI

// MARK: - Condition

/// A filter over cached messages. Empty/`.any`/`nil` fields are ignored; all
/// set fields must match (AND).
nonisolated struct MailCondition: Codable, Equatable {
    enum TriState: String, Codable, CaseIterable {
        case any, yes, no
    }

    var fromContains: String = ""
    var subjectContains: String = ""
    /// Restrict to one account (also enables the move-to action in rules).
    var accountID: UUID? = nil
    var unread: TriState = .any
    var flagged: TriState = .any
    /// Only messages newer than this many days. 0 = any time.
    var withinDays: Int = 0

    @MainActor
    func matches(_ message: MailMessage) -> Bool {
        if let accountID, message.accountID != accountID { return false }
        if !fromContains.isEmpty {
            let needle = fromContains.lowercased()
            let haystack = "\(message.fromName) \(message.fromAddress)".lowercased()
            if !haystack.contains(needle) { return false }
        }
        if !subjectContains.isEmpty,
           !message.subject.localizedCaseInsensitiveContains(subjectContains) { return false }
        switch unread {
        case .yes where message.isSeen: return false
        case .no where !message.isSeen: return false
        default: break
        }
        switch flagged {
        case .yes where !message.isFlagged: return false
        case .no where message.isFlagged: return false
        default: break
        }
        if withinDays > 0 {
            let cutoff = Date().addingTimeInterval(-TimeInterval(withinDays) * 86_400)
            if message.date < cutoff { return false }
        }
        return true
    }

    static func decode(_ data: Data) -> MailCondition {
        (try? JSONDecoder().decode(MailCondition.self, from: data)) ?? MailCondition()
    }

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }
}

// MARK: - Rule action

/// What a rule does to a matching incoming message.
nonisolated struct RuleAction: Codable, Equatable {
    var markRead = false
    var flag = false
    var addTagID: UUID? = nil
    /// Move to this mailbox path (requires the condition to pin an account).
    var moveToMailboxPath: String = ""
    var moveToTrash = false

    var isEmpty: Bool {
        !markRead && !flag && addTagID == nil && moveToMailboxPath.isEmpty && !moveToTrash
    }

    static func decode(_ data: Data) -> RuleAction {
        (try? JSONDecoder().decode(RuleAction.self, from: data)) ?? RuleAction()
    }

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }
}

// MARK: - Models

/// A saved search shown in the sidebar (local view over the cache).
@Model
final class SmartMailbox {
    var id: UUID = UUID()
    var name: String = ""
    var colorHex: String = ""
    var sortIndex: Int = 0
    var conditionJSON: Data = Data()

    init(name: String, colorHex: String = "", condition: MailCondition = MailCondition()) {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
        self.conditionJSON = condition.encoded()
    }

    var condition: MailCondition {
        get { MailCondition.decode(conditionJSON) }
        set { conditionJSON = newValue.encoded() }
    }
}

/// A rule applied to newly arrived INBOX messages at sync time.
@Model
final class MailRule {
    var id: UUID = UUID()
    var name: String = ""
    var isEnabled: Bool = true
    var sortIndex: Int = 0
    var conditionJSON: Data = Data()
    var actionJSON: Data = Data()

    init(name: String, condition: MailCondition = MailCondition(), action: RuleAction = RuleAction()) {
        self.id = UUID()
        self.name = name
        self.conditionJSON = condition.encoded()
        self.actionJSON = action.encoded()
    }

    var condition: MailCondition {
        get { MailCondition.decode(conditionJSON) }
        set { conditionJSON = newValue.encoded() }
    }

    var action: RuleAction {
        get { RuleAction.decode(actionJSON) }
        set { actionJSON = newValue.encoded() }
    }
}

/// A blocked sender address: newly arrived messages from it are moved straight
/// to Trash at sync time (checked before rules run).
@Model
final class BlockedSender {
    var id: UUID = UUID()
    /// Lowercased email address.
    var address: String = ""
    var createdAt: Date = Date()

    init(address: String) {
        self.id = UUID()
        self.address = address.trimmingCharacters(in: .whitespaces).lowercased()
        self.createdAt = Date()
    }
}

// MARK: - Shared condition form

/// The condition editor used by both the Smart Mailbox and Rule editors.
struct ConditionFormView: View {
    @Binding var condition: MailCondition
    let accounts: [MailAccount]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            LabeledContent("From contains") {
                TextField("sender or address", text: $condition.fromContains)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Subject contains") {
                TextField("any text", text: $condition.subjectContains)
                    .textFieldStyle(.roundedBorder)
            }
            Picker("Account", selection: $condition.accountID) {
                Text("Any account").tag(UUID?.none)
                ForEach(accounts) { account in
                    Text(account.emailAddress).tag(Optional(account.id))
                }
            }
            Picker("Read state", selection: $condition.unread) {
                Text("Any").tag(MailCondition.TriState.any)
                Text("Unread").tag(MailCondition.TriState.yes)
                Text("Read").tag(MailCondition.TriState.no)
            }
            .pickerStyle(.segmented)
            Picker("Flagged", selection: $condition.flagged) {
                Text("Any").tag(MailCondition.TriState.any)
                Text("Flagged").tag(MailCondition.TriState.yes)
                Text("Unflagged").tag(MailCondition.TriState.no)
            }
            .pickerStyle(.segmented)
            LabeledContent("Within days") {
                TextField("0 = any time", value: $condition.withinDays, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
        }
    }
}
