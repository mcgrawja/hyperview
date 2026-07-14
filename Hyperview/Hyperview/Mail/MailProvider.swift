//
//  MailProvider.swift
//  Unifyr
//
//  Works out the IMAP/SMTP servers for an email address.
//
//  The naive rule — imap.<domain> — is wrong for any domain whose mail is hosted
//  by somebody else. mcgraw.cc is an iCloud custom domain: imap.mcgraw.cc simply
//  doesn't exist, and the app sat on "Connecting…" forever because of it. So we
//  ask DNS which servers accept the domain's mail (its MX records) and map those
//  back to the provider's real IMAP/SMTP hosts.
//

import Foundation

nonisolated enum MailProvider {
    struct Settings: Equatable, Sendable {
        var imapHost: String
        var imapPort: Int
        var smtpHost: String
        var smtpPort: Int
    }

    /// What detection concluded, so the setup screen can explain itself.
    struct Detection: Sendable {
        var settings: Settings
        /// Plain-language note ("Your domain's mail is hosted by iCloud").
        var summary: String?
        /// Set when the servers are a guess we couldn't confirm.
        var warning: String?
    }

    // MARK: - Instant guess (no network)

    /// The old table lookup, still used to fill the fields the moment you finish
    /// typing an address. `detect` refines it.
    static func settings(for email: String) -> Settings {
        let domain = domain(of: email)
        if let known = known(for: domain) { return known }
        return Settings(imapHost: "imap.\(domain)", imapPort: 993, smtpHost: "smtp.\(domain)", smtpPort: 587)
    }

    // MARK: - DNS-backed detection

    /// Resolve the real servers for an address: the known-provider table first,
    /// then the domain's MX records, then a guess we verify actually resolves.
    static func detect(for email: String) async -> Detection {
        let domain = domain(of: email)
        guard !domain.isEmpty else {
            return Detection(settings: settings(for: email), summary: nil, warning: nil)
        }

        if let known = known(for: domain) {
            return Detection(settings: known, summary: "Using \(hostLabel(for: domain) ?? "your provider")'s servers.", warning: nil)
        }

        // Who accepts this domain's mail? For a custom domain on iCloud/Google/
        // Outlook, that's the only way to learn where the mailbox actually lives.
        let exchangers = await DNSLookup.mxHosts(for: domain)
        if let hosted = hostedProvider(forMX: exchangers) {
            return Detection(
                settings: hosted.settings,
                summary: "Your domain's mail is hosted by \(hosted.name) — using its servers.",
                warning: nil
            )
        }

        // Self-hosted or an unknown provider: imap.<domain> is the convention, but
        // only trust it if it actually exists.
        let guess = settings(for: email)
        if await DNSLookup.resolves(guess.imapHost) {
            return Detection(settings: guess, summary: nil, warning: nil)
        }
        return Detection(
            settings: guess,
            summary: nil,
            warning: "“\(guess.imapHost)” doesn't exist. Enter your provider's IMAP and SMTP servers below."
        )
    }

    // MARK: - Tables

    private struct Provider {
        let name: String
        let settings: Settings
        /// Suffixes of the MX hostnames this provider answers with.
        let mxSuffixes: [String]
        /// Email domains it owns outright.
        let domains: [String]
    }

    private static let providers: [Provider] = [
        Provider(
            name: "iCloud",
            settings: Settings(imapHost: "imap.mail.me.com", imapPort: 993, smtpHost: "smtp.mail.me.com", smtpPort: 587),
            mxSuffixes: ["icloud.com", "me.com", "mac.com", "apple.com"],
            domains: ["icloud.com", "me.com", "mac.com"]
        ),
        Provider(
            name: "Gmail",
            settings: Settings(imapHost: "imap.gmail.com", imapPort: 993, smtpHost: "smtp.gmail.com", smtpPort: 587),
            mxSuffixes: ["google.com", "googlemail.com", "googlemail.l.google.com"],
            domains: ["gmail.com", "googlemail.com"]
        ),
        Provider(
            name: "Outlook",
            settings: Settings(imapHost: "outlook.office365.com", imapPort: 993, smtpHost: "smtp.office365.com", smtpPort: 587),
            mxSuffixes: ["outlook.com", "office365.com", "protection.outlook.com", "hotmail.com"],
            domains: ["outlook.com", "hotmail.com", "live.com", "msn.com"]
        ),
        Provider(
            name: "Yahoo",
            settings: Settings(imapHost: "imap.mail.yahoo.com", imapPort: 993, smtpHost: "smtp.mail.yahoo.com", smtpPort: 587),
            mxSuffixes: ["yahoodns.net", "yahoo.com"],
            domains: ["yahoo.com"]
        ),
        Provider(
            name: "AOL",
            settings: Settings(imapHost: "imap.aol.com", imapPort: 993, smtpHost: "smtp.aol.com", smtpPort: 587),
            mxSuffixes: ["aol.com"],
            domains: ["aol.com"]
        ),
        Provider(
            name: "Fastmail",
            settings: Settings(imapHost: "imap.fastmail.com", imapPort: 993, smtpHost: "smtp.fastmail.com", smtpPort: 587),
            mxSuffixes: ["messagingengine.com", "fastmail.com"],
            domains: ["fastmail.com", "fastmail.fm"]
        ),
        // Proton is deliberately absent: it has no public IMAP, only a local
        // Bridge on 127.0.0.1, so "detecting" it would hand back a loopback
        // address that works on exactly one machine.
        Provider(
            name: "Zoho",
            settings: Settings(imapHost: "imap.zoho.com", imapPort: 993, smtpHost: "smtp.zoho.com", smtpPort: 587),
            mxSuffixes: ["zoho.com", "zohomail.com"],
            domains: ["zoho.com"]
        ),
    ]

    private static func known(for domain: String) -> Settings? {
        providers.first { $0.domains.contains(domain) }?.settings
    }

    private static func hostLabel(for domain: String) -> String? {
        providers.first { $0.domains.contains(domain) }?.name
    }

    private static func hostedProvider(forMX exchangers: [String]) -> (name: String, settings: Settings)? {
        for exchanger in exchangers {
            let host = exchanger.lowercased()
            for provider in providers {
                let matches = provider.mxSuffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
                if matches { return (provider.name, provider.settings) }
            }
        }
        return nil
    }

    private static func domain(of email: String) -> String {
        email.split(separator: "@").last.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }
}
