//
//  MailLog.swift
//  Hyperview
//
//  Lightweight, toggleable logging for the mail stack. The mail layer is
//  from-scratch and still hardening (D9), so protocol-level tracing is valuable
//  during development. Flip `verbose` to false to silence it. When enabled and
//  stdout is captured, logs stream in real time (stdout is unbuffered — see
//  HyperviewApp.init).
//

import Foundation

nonisolated enum MailLog {
    /// Set to false to silence IMAP/SMTP tracing.
    static let verbose = true

    static func log(_ message: @autoclosure () -> String) {
        if verbose { print(message()) }
    }
}
