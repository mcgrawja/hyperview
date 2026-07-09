//
//  ContactsBroker.swift
//  Hyperview
//
//  §3 / §6 — Contacts. Actor over CNContactStore. Keys are fetched minimally
//  per view. Verbs map 1:1 to MCP tools (§7):
//    fetch / search  -> contacts_search
//    get             -> contacts_get
//

import Foundation
import Contacts

actor ContactsBroker: DataBroker {
    typealias Item = ContactSnapshot

    private let store = CNContactStore()

    /// The minimal key set the dashboard + search need. Widen deliberately if a
    /// view needs more; do not fetch everything.
    // CNKeyDescriptor values are immutable string keys; safe to share.
    nonisolated(unsafe) private static let keys: [CNKeyDescriptor] = [
        CNContactGivenNameKey,
        CNContactFamilyNameKey,
        CNContactOrganizationNameKey,
        CNContactEmailAddressesKey,
        CNContactPhoneNumbersKey,
        CNContactThumbnailImageDataKey,
    ].map { $0 as CNKeyDescriptor }

    // MARK: Authorization

    func requestAccess() async throws {
        let granted: Bool = try await withCheckedThrowingContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, error in
                if let error { continuation.resume(throwing: BrokerError.underlying(error.localizedDescription)) }
                else { continuation.resume(returning: granted) }
            }
        }
        guard granted else { throw BrokerError.accessDenied }
    }

    nonisolated var authorization: BrokerAuthorization {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        case .limited: return .limited
        @unknown default: return .denied
        }
    }

    // MARK: Read

    /// `fetch` searches by name when `searchText` is set, otherwise returns the
    /// address book (bounded by `limit`, default 100 to keep the dashboard snappy).
    func fetch(_ query: BrokerQuery) async throws -> [ContactSnapshot] {
        try ensureAuthorized()
        let limit = query.limit ?? 100

        if let text = query.searchText, !text.isEmpty {
            let predicate = CNContact.predicateForContacts(matchingName: text)
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: Self.keys)
            return Array(contacts.prefix(limit)).map(Self.snapshot(from:))
        }

        var results: [ContactSnapshot] = []
        let request = CNContactFetchRequest(keysToFetch: Self.keys)
        request.sortOrder = .userDefault
        try store.enumerateContacts(with: request) { contact, stop in
            results.append(Self.snapshot(from: contact))
            if results.count >= limit { stop.pointee = true }
        }
        return results
    }

    /// First contact whose email matches (exact, case-insensitive), if any.
    func findByEmail(_ email: String) async throws -> ContactSnapshot? {
        try ensureAuthorized()
        let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
        let matches = try store.unifiedContacts(matching: predicate, keysToFetch: Self.keys)
        return matches.first.map(Self.snapshot(from:))
    }

    /// Create a contact (used by "Add Sender to Contacts"; the future
    /// contacts_create tool).
    @discardableResult
    func addContact(givenName: String, familyName: String, email: String?) async throws -> ContactSnapshot {
        try ensureAuthorized()
        let contact = CNMutableContact()
        contact.givenName = givenName
        contact.familyName = familyName
        if let email, !email.isEmpty {
            contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: email as NSString)]
        }
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        do {
            try store.execute(request)
        } catch {
            throw BrokerError.underlying(error.localizedDescription)
        }
        return Self.snapshot(from: contact)
    }

    /// Fetch one contact by identifier (`contacts_get`).
    func get(id: String) async throws -> ContactSnapshot {
        try ensureAuthorized()
        do {
            let contact = try store.unifiedContact(withIdentifier: id, keysToFetch: Self.keys)
            return Self.snapshot(from: contact)
        } catch {
            throw BrokerError.notFound
        }
    }

    // MARK: Change feed

    nonisolated func changes() -> AsyncStream<BrokerChange<ContactSnapshot>> {
        AsyncStream { continuation in
            // Token is only ever passed to removeObserver; safe to share.
            nonisolated(unsafe) let token = NotificationCenter.default.addObserver(
                forName: .CNContactStoreDidChange,
                object: nil,
                queue: nil
            ) { _ in
                continuation.yield(.reloaded)
            }
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(token)
            }
        }
    }

    // MARK: - Helpers

    private func ensureAuthorized() throws {
        switch authorization {
        case .authorized, .limited: return
        case .restricted: throw BrokerError.accessRestricted
        default: throw BrokerError.accessDenied
        }
    }

    private static func snapshot(from contact: CNContact) -> ContactSnapshot {
        ContactSnapshot(
            id: contact.identifier,
            givenName: contact.givenName,
            familyName: contact.familyName,
            organizationName: contact.organizationName.isEmpty ? nil : contact.organizationName,
            emailAddresses: contact.emailAddresses.map { $0.value as String },
            phoneNumbers: contact.phoneNumbers.map { $0.value.stringValue },
            thumbnail: contact.thumbnailImageData
        )
    }
}
