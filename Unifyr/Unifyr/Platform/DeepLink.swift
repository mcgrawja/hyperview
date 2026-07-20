//
//  DeepLink.swift
//  Unifyr
//
//  Cross-module "open this item" handoff. The old pattern — switch modules,
//  then post the notification after a fixed 0.4s — silently dropped the open
//  whenever the destination mounted slower than the timer (cold module, busy
//  main thread). Here the notification is posted immediately AND latched:
//  an already-mounted destination handles the live post (its onReceive also
//  consumes the latch), and a destination that mounts later finds the latch
//  waiting in its .task/onAppear. Nothing races, nothing drops.
//

import Foundation

@MainActor
enum DeepLink {
    private static var pending: [Notification.Name: [String: Any]] = [:]

    /// Post now for mounted listeners and latch for late mounters.
    static func send(_ name: Notification.Name, userInfo: [String: Any]) {
        pending[name] = userInfo
        NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
    }

    /// Consume (and clear) a latched deep link. Destinations call this from
    /// BOTH their mount path (.task/onAppear) and their live onReceive.
    @discardableResult
    static func take(_ name: Notification.Name) -> [String: Any]? {
        pending.removeValue(forKey: name)
    }
}
