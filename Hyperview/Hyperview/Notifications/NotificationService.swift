//
//  NotificationService.swift
//  Hyperview
//
//  Hyperview as the single notification hub: the user silences Apple's Mail /
//  Reminders / Calendar / Messages and lets Hyperview surface everything. Each
//  notification carries a rendered type icon (Mail, Reminder, Calendar,
//  Message, Clock) shown at the trailing edge of the banner, and tapping one
//  opens the matching module. Also owns the Dock badge for total outstanding
//  items.
//
//  Uses the standard UserNotifications framework — works inside the App
//  Sandbox with no extra entitlement. Immediate alerts (new mail/message) are
//  delivered now; time-based ones (reminders due, events starting, timers,
//  alarms) are SCHEDULED with calendar triggers so macOS fires them even when
//  Hyperview is in the background.
//

import Foundation
import UserNotifications
import AppKit
import SwiftUI

/// The kinds of thing Hyperview notifies about. `symbol`/`tint` drive the
/// trailing icon; `module` drives tap-to-open routing.
nonisolated enum NotificationKind: String, CaseIterable, Sendable {
    case mail, reminder, calendar, message, clock

    var symbol: String {
        switch self {
        case .mail: return "envelope.fill"
        case .reminder: return "checklist"
        case .calendar: return "calendar"
        case .message: return "message.fill"
        case .clock: return "clock.fill"
        }
    }

    /// Hex tint for the icon badge (mirrors Theme; kept literal here because
    /// icon rendering happens off the SwiftUI Color type).
    var tintHex: UInt32 {
        switch self {
        case .mail, .reminder, .calendar, .clock: return 0x3E8EF7 // primary blue
        case .message: return 0x34C759                            // iMessage green
        }
    }

    /// Sidebar module a tap should open.
    var moduleRaw: String {
        switch self {
        case .mail: return "mail"
        case .reminder: return "reminders"
        case .calendar: return "calendar"
        case .message: return "messages"
        case .clock: return "clock"
        }
    }
}

extension Notification.Name {
    /// Posted when a notification is tapped; userInfo ["module": String].
    static let hyperviewOpenModule = Notification.Name("hyperview.openModule")
}

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()
    private var authorized = false
    /// Cached on-disk icon file per kind (rendered once).
    private var iconURLs: [NotificationKind: URL] = [:]

    private override init() { super.init() }

    /// Call once at launch: become the delegate and request permission.
    func bootstrap() {
        center.delegate = self
        Task {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            authorized = granted
        }
    }

    // MARK: Immediate alerts

    /// Fire a notification now (new mail / message). `threadKey` coalesces
    /// repeats (e.g. one thread) so the banner updates instead of stacking.
    func notify(kind: NotificationKind, title: String, body: String, threadKey: String? = nil, userInfo: [String: String] = [:]) {
        let content = makeContent(kind: kind, title: title, body: body, userInfo: userInfo, threadKey: threadKey)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }

    // MARK: Scheduled alerts (reminders, events, timers, alarms)

    /// Schedule (or reschedule — same `identifier` replaces) a notification at
    /// `date`. Past dates are dropped. `repeatsDaily` powers alarms.
    func schedule(
        kind: NotificationKind,
        identifier: String,
        title: String,
        body: String,
        at date: Date,
        repeatsDaily: Bool = false,
        userInfo: [String: String] = [:]
    ) {
        guard repeatsDaily || date > Date() else { return }
        let content = makeContent(kind: kind, title: title, body: body, userInfo: userInfo, threadKey: nil)
        let components: DateComponents = repeatsDaily
            ? Calendar.current.dateComponents([.hour, .minute], from: date)
            : Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: repeatsDaily)
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    /// Remove scheduled notifications by identifier prefix (used when
    /// re-syncing reminders/events so stale future items don't linger).
    func cancelScheduled(withPrefix prefix: String) {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    func cancel(identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// Fire after `seconds` from now — used by the Clock timer (second
    /// precision, which calendar triggers can't give cleanly).
    func scheduleInterval(
        kind: NotificationKind,
        identifier: String,
        title: String,
        body: String,
        after seconds: TimeInterval
    ) {
        guard seconds > 0 else { return }
        let content = makeContent(kind: kind, title: title, body: body, userInfo: [:], threadKey: nil)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    // MARK: Dock badge

    /// Total outstanding items across the app (unread mail + messages + due
    /// reminders). 0 clears the badge.
    func setBadge(_ count: Int) {
        center.setBadgeCount(max(0, count))
    }

    // MARK: Content + icon

    private func makeContent(kind: NotificationKind, title: String, body: String, userInfo: [String: String], threadKey: String?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        var info = userInfo
        info["module"] = kind.moduleRaw
        content.userInfo = info
        if let threadKey { content.threadIdentifier = threadKey }
        if let attachment = iconAttachment(for: kind) {
            content.attachments = [attachment]
        }
        return content
    }

    /// The trailing-edge type icon: an SF Symbol on a rounded tinted tile,
    /// rendered once to a PNG in caches and reused.
    private func iconAttachment(for kind: NotificationKind) -> UNNotificationAttachment? {
        let url: URL
        if let cached = iconURLs[kind] {
            url = cached
        } else {
            guard let rendered = renderIcon(for: kind) else { return nil }
            iconURLs[kind] = rendered
            url = rendered
        }
        return try? UNNotificationAttachment(identifier: "icon-\(kind.rawValue)", url: url, options: nil)
    }

    private func renderIcon(for kind: NotificationKind) -> URL? {
        let side: CGFloat = 128
        let hex = kind.tintHex
        let tint = NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        // Rounded tinted tile.
        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        let tile = NSBezierPath(roundedRect: rect, xRadius: 28, yRadius: 28)
        tint.setFill()
        tile.fill()
        // White SF Symbol centered.
        let config = NSImage.SymbolConfiguration(pointSize: 68, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let s = symbol.size
            let origin = NSPoint(x: (side - s.width) / 2, y: (side - s.height) / 2)
            symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
        }
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appending(path: "hv-notif-icons", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "\(kind.rawValue).png")
        try? png.write(to: file)
        return file
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show banners even while Hyperview is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// Tap → open the module.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let module = response.notification.request.content.userInfo["module"] as? String
        completionHandler()
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let module {
                NotificationCenter.default.post(name: .hyperviewOpenModule, object: nil, userInfo: ["module": module])
            }
        }
    }
}
