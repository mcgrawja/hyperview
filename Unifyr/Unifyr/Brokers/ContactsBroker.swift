//
//  ContactsBroker.swift
//  Unifyr
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

    /// The full card the Contacts module edits. (CNContactNoteKey is absent on
    /// purpose: reading/writing notes requires the Apple-approved
    /// com.apple.developer.contacts.notes entitlement.)
    // CNKeyDescriptor values are immutable string keys; safe to share.
    nonisolated(unsafe) private static let keys: [CNKeyDescriptor] = [
        CNContactNamePrefixKey,
        CNContactGivenNameKey,
        CNContactMiddleNameKey,
        CNContactFamilyNameKey,
        CNContactNameSuffixKey,
        CNContactNicknameKey,
        CNContactPhoneticGivenNameKey,
        CNContactPhoneticFamilyNameKey,
        CNContactOrganizationNameKey,
        CNContactDepartmentNameKey,
        CNContactJobTitleKey,
        CNContactBirthdayKey,
        CNContactDatesKey,
        CNContactEmailAddressesKey,
        CNContactPhoneNumbersKey,
        CNContactUrlAddressesKey,
        CNContactPostalAddressesKey,
        CNContactRelationsKey,
        CNContactSocialProfilesKey,
        CNContactInstantMessageAddressesKey,
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

    /// Update an existing contact; nil fields are left unchanged. Email/phone
    /// arrays REPLACE the existing sets when provided.
    @discardableResult
    func updateContact(
        id: String,
        givenName: String? = nil,
        familyName: String? = nil,
        organization: String? = nil,
        emails: [String]? = nil,
        phones: [String]? = nil
    ) async throws -> ContactSnapshot {
        try ensureAuthorized()
        guard let existing = try? store.unifiedContact(withIdentifier: id, keysToFetch: Self.keys),
              let contact = existing.mutableCopy() as? CNMutableContact else {
            throw BrokerError.notFound
        }
        if let givenName { contact.givenName = givenName }
        if let familyName { contact.familyName = familyName }
        if let organization { contact.organizationName = organization }
        if let emails {
            contact.emailAddresses = emails
                .filter { !$0.isEmpty }
                .map { CNLabeledValue(label: CNLabelHome, value: $0 as NSString) }
        }
        if let phones {
            contact.phoneNumbers = phones
                .filter { !$0.isEmpty }
                .map { CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: $0)) }
        }
        let request = CNSaveRequest()
        request.update(contact)
        do {
            try store.execute(request)
        } catch {
            throw BrokerError.underlying(error.localizedDescription)
        }
        return Self.snapshot(from: contact)
    }

    /// Full-card save used by the Contacts editor: every Apple-Contacts field.
    /// Replaces the whole card with `edit`'s contents (the editor loads the
    /// full card first, so nothing is lost). `id == nil` creates a new contact.
    @discardableResult
    func saveContact(id: String?, edit: ContactEditData) async throws -> ContactSnapshot {
        try ensureAuthorized()
        let contact: CNMutableContact
        let request = CNSaveRequest()
        if let id {
            guard let existing = try? store.unifiedContact(withIdentifier: id, keysToFetch: Self.keys),
                  let mutable = existing.mutableCopy() as? CNMutableContact else {
                throw BrokerError.notFound
            }
            contact = mutable
            request.update(contact)
        } else {
            contact = CNMutableContact()
            request.add(contact, toContainerWithIdentifier: nil)
        }

        contact.namePrefix = edit.namePrefix
        contact.givenName = edit.givenName
        contact.middleName = edit.middleName
        contact.familyName = edit.familyName
        contact.nameSuffix = edit.nameSuffix
        contact.nickname = edit.nickname
        contact.phoneticGivenName = edit.phoneticGivenName
        contact.phoneticFamilyName = edit.phoneticFamilyName
        contact.organizationName = edit.organizationName
        contact.departmentName = edit.departmentName
        contact.jobTitle = edit.jobTitle
        contact.birthday = edit.birthday.map {
            Calendar.current.dateComponents([.year, .month, .day], from: $0)
        }
        contact.emailAddresses = edit.emails
            .filter { !$0.value.isEmpty }
            .map { CNLabeledValue(label: Self.canonicalLabel($0.label), value: $0.value as NSString) }
        contact.phoneNumbers = edit.phones
            .filter { !$0.value.isEmpty }
            .map { CNLabeledValue(label: Self.canonicalLabel($0.label), value: CNPhoneNumber(stringValue: $0.value)) }
        contact.urlAddresses = edit.urls
            .filter { !$0.value.isEmpty }
            .map { CNLabeledValue(label: Self.canonicalLabel($0.label), value: $0.value as NSString) }
        contact.postalAddresses = edit.postalAddresses
            .filter { !($0.street.isEmpty && $0.city.isEmpty && $0.state.isEmpty && $0.postalCode.isEmpty) }
            .map { address in
                let postal = CNMutablePostalAddress()
                postal.street = address.street
                postal.city = address.city
                postal.state = address.state
                postal.postalCode = address.postalCode
                postal.country = address.country
                return CNLabeledValue(label: Self.canonicalLabel(address.label), value: postal as CNPostalAddress)
            }
        contact.contactRelations = edit.relations
            .filter { !$0.value.isEmpty }
            .map { CNLabeledValue(label: Self.canonicalLabel($0.label), value: CNContactRelation(name: $0.value)) }
        contact.socialProfiles = edit.socialProfiles
            .filter { !$0.value.isEmpty }
            .map {
                CNLabeledValue(
                    label: $0.label,
                    value: CNSocialProfile(urlString: nil, username: $0.value, userIdentifier: nil, service: $0.label)
                )
            }
        contact.instantMessageAddresses = edit.instantMessages
            .filter { !$0.value.isEmpty }
            .map {
                CNLabeledValue(
                    label: $0.label,
                    value: CNInstantMessageAddress(username: $0.value, service: $0.label)
                )
            }
        contact.dates = edit.dates.map {
            let components = Calendar.current.dateComponents([.year, .month, .day], from: $0.date)
            return CNLabeledValue(label: Self.canonicalLabel($0.label), value: components as NSDateComponents)
        }

        do {
            try store.execute(request)
        } catch {
            throw BrokerError.underlying(error.localizedDescription)
        }
        return Self.snapshot(from: contact)
    }

    /// Delete a contact permanently.
    func deleteContact(id: String) async throws {
        try ensureAuthorized()
        guard let existing = try? store.unifiedContact(withIdentifier: id, keysToFetch: Self.keys),
              let contact = existing.mutableCopy() as? CNMutableContact else {
            throw BrokerError.notFound
        }
        let request = CNSaveRequest()
        request.delete(contact)
        do {
            try store.execute(request)
        } catch {
            throw BrokerError.underlying(error.localizedDescription)
        }
    }

    // MARK: Groups

    /// The user's contact groups (Contacts-app groups; they sync via iCloud).
    func groups() async throws -> [ContactGroupSnapshot] {
        try ensureAuthorized()
        let groups = (try? store.groups(matching: nil)) ?? []
        return groups
            .map { ContactGroupSnapshot(id: $0.identifier, name: $0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Contacts belonging to a group.
    func fetch(inGroup groupID: String, limit: Int = 500) async throws -> [ContactSnapshot] {
        try ensureAuthorized()
        let predicate = CNContact.predicateForContactsInGroup(withIdentifier: groupID)
        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: Self.keys)
        return Array(contacts.prefix(limit)).map(Self.snapshot(from:))
    }

    @discardableResult
    func createGroup(name: String) async throws -> ContactGroupSnapshot {
        try ensureAuthorized()
        let group = CNMutableGroup()
        group.name = name
        let request = CNSaveRequest()
        request.add(group, toContainerWithIdentifier: nil)
        do {
            try store.execute(request)
        } catch {
            throw BrokerError.underlying(error.localizedDescription)
        }
        return ContactGroupSnapshot(id: group.identifier, name: group.name)
    }

    /// Delete a group (members stay in the address book).
    func deleteGroup(id: String) async throws {
        try ensureAuthorized()
        guard let group = try? store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [id])).first,
              let mutable = group.mutableCopy() as? CNMutableGroup else {
            throw BrokerError.notFound
        }
        let request = CNSaveRequest()
        request.delete(mutable)
        do {
            try store.execute(request)
        } catch {
            throw BrokerError.underlying(error.localizedDescription)
        }
    }

    func setMembership(contactID: String, groupID: String, isMember: Bool) async throws {
        try ensureAuthorized()
        guard let group = try? store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [groupID])).first,
              let contact = try? store.unifiedContact(withIdentifier: contactID, keysToFetch: []) else {
            throw BrokerError.notFound
        }
        let request = CNSaveRequest()
        if isMember {
            request.addMember(contact, to: group)
        } else {
            request.removeMember(contact, from: group)
        }
        do {
            try store.execute(request)
        } catch {
            throw BrokerError.underlying(error.localizedDescription)
        }
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
            thumbnail: contact.thumbnailImageData,
            namePrefix: contact.namePrefix,
            middleName: contact.middleName,
            nameSuffix: contact.nameSuffix,
            nickname: contact.nickname,
            phoneticGivenName: contact.phoneticGivenName,
            phoneticFamilyName: contact.phoneticFamilyName,
            jobTitle: contact.jobTitle,
            departmentName: contact.departmentName,
            birthday: contact.birthday.flatMap { Calendar.current.date(from: $0) },
            emails: contact.emailAddresses.map {
                LabeledValueSnapshot(label: displayLabel($0.label), value: $0.value as String)
            },
            phones: contact.phoneNumbers.map {
                LabeledValueSnapshot(label: displayLabel($0.label), value: $0.value.stringValue)
            },
            urls: contact.urlAddresses.map {
                LabeledValueSnapshot(label: displayLabel($0.label), value: $0.value as String)
            },
            postalAddresses: contact.postalAddresses.map { labeled in
                PostalAddressSnapshot(
                    label: displayLabel(labeled.label),
                    street: labeled.value.street,
                    city: labeled.value.city,
                    state: labeled.value.state,
                    postalCode: labeled.value.postalCode,
                    country: labeled.value.country
                )
            },
            relations: contact.contactRelations.map {
                LabeledValueSnapshot(label: displayLabel($0.label), value: $0.value.name)
            },
            socialProfiles: contact.socialProfiles.map {
                LabeledValueSnapshot(label: $0.value.service, value: $0.value.username)
            },
            instantMessages: contact.instantMessageAddresses.map {
                LabeledValueSnapshot(label: $0.value.service, value: $0.value.username)
            },
            dates: contact.dates.compactMap { labeled in
                Calendar.current.date(from: labeled.value as DateComponents).map {
                    ContactDateSnapshot(label: displayLabel(labeled.label), date: $0)
                }
            }
        )
    }

    /// "home" / "work" / "mobile" → Apple's canonical `_$!<Home>!$_`-style
    /// constants so other apps localize them; anything else is kept verbatim
    /// as a custom label.
    nonisolated static func canonicalLabel(_ label: String) -> String {
        switch label.trimmingCharacters(in: .whitespaces).lowercased() {
        case "home": return CNLabelHome
        case "work": return CNLabelWork
        case "school": return CNLabelSchool
        case "other": return CNLabelOther
        case "mobile": return CNLabelPhoneNumberMobile
        case "iphone": return CNLabelPhoneNumberiPhone
        case "main": return CNLabelPhoneNumberMain
        case "home fax": return CNLabelPhoneNumberHomeFax
        case "work fax": return CNLabelPhoneNumberWorkFax
        case "pager": return CNLabelPhoneNumberPager
        case "anniversary": return CNLabelDateAnniversary
        case "mother": return CNLabelContactRelationMother
        case "father": return CNLabelContactRelationFather
        case "parent": return CNLabelContactRelationParent
        case "brother": return CNLabelContactRelationBrother
        case "sister": return CNLabelContactRelationSister
        case "child": return CNLabelContactRelationChild
        case "friend": return CNLabelContactRelationFriend
        case "spouse": return CNLabelContactRelationSpouse
        case "partner": return CNLabelContactRelationPartner
        case "assistant": return CNLabelContactRelationAssistant
        case "manager": return CNLabelContactRelationManager
        case "": return CNLabelOther
        default: return label
        }
    }

    /// Canonical constants → human text for the editor fields.
    nonisolated static func displayLabel(_ label: String?) -> String {
        guard let label, !label.isEmpty else { return "" }
        return CNLabeledValue<NSString>.localizedString(forLabel: label)
    }
}

/// Everything the Contacts editor can set — the full Apple-Contacts card
/// (minus notes, which need a restricted entitlement).
nonisolated struct ContactEditData: Sendable {
    var namePrefix = ""
    var givenName = ""
    var middleName = ""
    var familyName = ""
    var nameSuffix = ""
    var nickname = ""
    var phoneticGivenName = ""
    var phoneticFamilyName = ""
    var organizationName = ""
    var departmentName = ""
    var jobTitle = ""
    var birthday: Date?
    var emails: [LabeledValueSnapshot] = []
    var phones: [LabeledValueSnapshot] = []
    var urls: [LabeledValueSnapshot] = []
    var postalAddresses: [PostalAddressSnapshot] = []
    var relations: [LabeledValueSnapshot] = []
    var socialProfiles: [LabeledValueSnapshot] = []
    var instantMessages: [LabeledValueSnapshot] = []
    var dates: [ContactDateSnapshot] = []
}
