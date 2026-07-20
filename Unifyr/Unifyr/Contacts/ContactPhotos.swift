//
//  ContactPhotos.swift
//  Unifyr
//
//  One shared contact-photo lookup, so a face can appear anywhere a person does
//  — a mail sender, a message thread, a contact row — instead of only in
//  Contacts.
//
//  Built as a CACHE on purpose. The obvious approach, calling
//  `ContactsBroker.findByEmail` per row, hits CNContactStore once per visible
//  message: a store round-trip per row, on the main thread, while scrolling. We
//  instead read the address book once and index it by every email and phone the
//  person has.
//
//  Reality check on coverage: of Jason's 193 contacts, exactly 25 carry photo
//  data that the Contacts framework will hand out. The faces Apple's own apps
//  show for everyone else are Apple-ID avatars and contact posters, which are
//  private to Apple and unreachable from any third-party app. So the initials
//  fallback below is not a placeholder for a bug — for most people it IS the
//  answer, and it needs to look deliberate.
//

import SwiftUI

@MainActor
@Observable
final class ContactPhotoStore {
    /// Photo data keyed by lowercased email.
    private var byEmail: [String: Data] = [:]
    /// Photo data keyed by the last 10 digits of a phone number (see `phoneKey`).
    private var byPhone: [String: Data] = [:]
    /// Display names, same keys — Mail shows a sender's real name over the raw
    /// address when we know it.
    private var namesByEmail: [String: String] = [:]

    private var isLoaded = false
    private var isLoading = false

    /// Read the address book once. Safe to call from every view's `.task`.
    func loadIfNeeded(_ brokers: Brokers) async {
        guard !isLoaded, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        // Lite fetch: name/emails/phones/thumbnail only — the full-key fetch
        // decoded every field of every contact just to build this index.
        guard let contacts = try? await brokers.contacts.fetchIndex(limit: 5000, includeThumbnails: true) else { return }
        for contact in contacts {
            let name = contact.displayName
            for email in contact.emailAddresses {
                let key = email.lowercased()
                namesByEmail[key] = name.isEmpty ? nil : name
                if let photo = contact.thumbnail { byEmail[key] = photo }
            }
            guard let photo = contact.thumbnail else { continue }
            for phone in contact.phoneNumbers {
                byPhone[Self.phoneKey(phone)] = photo
            }
        }
        isLoaded = true
    }

    func photo(email: String?) -> Data? {
        guard let email, !email.isEmpty else { return nil }
        return byEmail[email.lowercased()]
    }

    /// Handles arrive from Messages as anything from "+1 (555) 010-1234" to a
    /// bare 10-digit string, and from an iMessage as an email address — so try
    /// both indexes.
    func photo(handle: String?) -> Data? {
        guard let handle, !handle.isEmpty else { return nil }
        if handle.contains("@") { return photo(email: handle) }
        return byPhone[Self.phoneKey(handle)]
    }

    func name(email: String?) -> String? {
        guard let email, !email.isEmpty else { return nil }
        return namesByEmail[email.lowercased()]
    }

    /// Phone numbers are written a dozen ways; the last 10 digits are the stable
    /// part (dropping country code, punctuation, and spacing).
    static func phoneKey(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        return String(digits.suffix(10))
    }
}

/// A person, as a circle: their photo when we have one, their initials when we
/// don't. Shared by Contacts, Mail, and Messages so all three look alike.
struct ContactAvatar: View {
    /// Photo bytes, if the contact has one.
    var data: Data?
    /// Falls back to initials derived from this.
    var name: String
    var size: CGFloat = 36
    /// Tints the initials circle — Messages colors threads by participant.
    var tint: Color = Theme.Palette.primary

    var body: some View {
        Group {
            if let data, let image = Self.image(from: data) {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(tint.opacity(0.15))
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    /// Initials from a display name, or the first letter of an address when the
    /// name IS an address ("noreply@stripe.com" → "N").
    private var initials: String {
        let words = name
            .split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" })
            .prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    private static func image(from data: Data) -> Image? {
        guard let platform = PlatformImage(data: data) else { return nil }
        return Image(platformImage: platform)
    }
}
