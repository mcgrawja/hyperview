//
//  DNSLookup.swift
//  Unifyr
//
//  Small DNS helpers used to work out where a domain's mail actually lives.
//
//  Why this exists: setup used to guess `imap.<your-domain>` for any domain it
//  didn't recognize. That's wrong for every domain whose mail is hosted
//  elsewhere — an iCloud or Google custom domain — and the guess produced a host
//  that doesn't resolve at all. Asking DNS who accepts the domain's mail (its MX
//  records) answers the question properly.
//

import Foundation
import dnssd

nonisolated enum DNSLookup {
    /// The mail exchangers for a domain, lowest preference (highest priority)
    /// first. Empty if the domain has none, or on any failure — callers treat
    /// that as "no idea", never as an error.
    static func mxHosts(for domain: String, timeout: TimeInterval = 3) async -> [String] {
        let domain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !domain.isEmpty else { return [] }

        return await withCheckedContinuation { continuation in
            let collector = MXCollector(continuation: continuation)
            let context = Unmanaged.passRetained(collector).toOpaque()

            var ref: DNSServiceRef?
            let status = DNSServiceQueryRecord(
                &ref, 0, 0, domain,
                UInt16(kDNSServiceType_MX), UInt16(kDNSServiceClass_IN),
                mxQueryCallback, context
            )
            guard status == kDNSServiceErr_NoError, let ref else {
                Unmanaged<MXCollector>.fromOpaque(context).release()
                continuation.resume(returning: [])
                return
            }

            // Callbacks and the deadline both run on this serial queue, so the
            // collector needs no further synchronization.
            let queue = DispatchQueue(label: "com.mcgraw.Hyperview.dns")
            collector.ref = ref
            DNSServiceSetDispatchQueue(ref, queue)
            queue.asyncAfter(deadline: .now() + timeout) { collector.finish() }
        }
    }

    /// Whether a hostname resolves at all. Used to catch a guessed server that
    /// simply doesn't exist before the user is left staring at a failed connect.
    static func resolves(_ host: String) async -> Bool {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return false }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo(
                    ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                    ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
                )
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &result)
                if let result { freeaddrinfo(result) }
                continuation.resume(returning: status == 0)
            }
        }
    }
}

/// Accumulates MX answers for one query and resumes the continuation exactly
/// once — whether the query completes, errors, or hits the deadline.
///
/// `nonisolated` because the project defaults to MainActor isolation and this
/// lives entirely on the DNS queue.
private nonisolated final class MXCollector: @unchecked Sendable {
    private var continuation: CheckedContinuation<[String], Never>?
    /// (preference, host) — preference orders the results.
    private var answers: [(UInt16, String)] = []
    var ref: DNSServiceRef?

    init(continuation: CheckedContinuation<[String], Never>) {
        self.continuation = continuation
    }

    func add(preference: UInt16, host: String) {
        answers.append((preference, host))
    }

    func finish() {
        guard let continuation else { return }
        self.continuation = nil
        if let ref { DNSServiceRefDeallocate(ref) }
        ref = nil
        let hosts = answers.sorted { $0.0 < $1.0 }.map(\.1)
        continuation.resume(returning: hosts)
        Unmanaged.passUnretained(self).release()
    }
}

/// A top-level `nonisolated` function, not a closure: this is passed to C as a
/// bare function pointer, so it can carry no captures and no actor isolation.
private nonisolated func mxQueryCallback(
    _ sdRef: DNSServiceRef?,
    _ flags: DNSServiceFlags,
    _ interfaceIndex: UInt32,
    _ errorCode: DNSServiceErrorType,
    _ fullname: UnsafePointer<CChar>?,
    _ rrtype: UInt16,
    _ rrclass: UInt16,
    _ rdlen: UInt16,
    _ rdata: UnsafeRawPointer?,
    _ ttl: UInt32,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let collector = Unmanaged<MXCollector>.fromOpaque(context).takeUnretainedValue()

    if errorCode == kDNSServiceErr_NoError,
       rrtype == UInt16(kDNSServiceType_MX),
       let rdata, rdlen > 3 {
        let bytes = UnsafeRawBufferPointer(start: rdata, count: Int(rdlen))
        // MX RDATA: a 2-byte preference, then the exchange as wire-format DNS
        // labels (each length-prefixed, terminated by a zero byte). mDNSResponder
        // hands back fully expanded names, so there are no compression pointers
        // to follow — but bail out if one ever shows up rather than emit garbage.
        let preference = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        var labels: [String] = []
        var index = 2
        while index < bytes.count {
            let length = Int(bytes[index])
            if length == 0 { break }
            if length & 0xC0 != 0 { labels.removeAll(); break }
            index += 1
            guard index + length <= bytes.count else { labels.removeAll(); break }
            labels.append(String(decoding: bytes[index..<(index + length)], as: UTF8.self))
            index += length
        }
        if !labels.isEmpty {
            collector.add(preference: preference, host: labels.joined(separator: "."))
        }
    }

    // No more records coming: answer now instead of waiting out the deadline.
    if flags & kDNSServiceFlagsMoreComing == 0 {
        collector.finish()
    }
}
