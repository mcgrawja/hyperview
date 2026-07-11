//
//  ClaudeView.swift
//  Hyperview
//
//  Phase 6 control surface: MCP server toggle + status, Claude Desktop setup
//  (exact config with copy button), and the tool-invocation audit log (§7).
//  A future Phase 5 adds the in-app API chat alongside — same tool registry.
//

import SwiftUI
import SwiftData

struct ClaudeView: View {
    @Environment(\.mcp) private var mcp
    @Environment(\.automationContainer) private var automationContainer

    private enum Pane: String, CaseIterable {
        case chat = "Chat"
        case automation = "Automation"
        case usage = "Usage"
    }

    @State private var pane: Pane = .chat

    var body: some View {
        Group {
            if let mcp, let automationContainer {
                VStack(spacing: 0) {
                    Picker("", selection: $pane) {
                        ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 280)
                    .padding(.vertical, Theme.Spacing.sm)

                    switch pane {
                    case .chat:
                        ClaudeChatView()
                    case .automation:
                        ClaudeContent(mcp: mcp)
                            .modelContainer(automationContainer)
                    case .usage:
                        UsageView()
                    }
                }
                .background(Theme.Palette.background)
            } else {
                Text("Claude layer unavailable.").foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .navigationTitle("Claude")
    }
}

private struct ClaudeContent: View {
    @Bindable var mcp: MCPController
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header
                serverCard
                setupCard
                AuditLogSection()
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.Palette.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.Palette.claude)
                Text("Claude + Hyperview")
                    .font(Theme.Font.dashboardTitle)
            }
            Text("Expose your notes, mail, calendar, reminders, contacts, and photos to Claude Desktop as MCP tools. Claude reads by default; mail can only be drafted, never sent. Every tool call is logged below.")
                .font(Theme.Font.cardBody)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private var serverCard: some View {
        DashboardCard(title: "MCP Server", systemImage: "server.rack", accent: Theme.Palette.claude) {
            HStack(spacing: Theme.Spacing.md) {
                Toggle("", isOn: $mcp.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                switch mcp.status {
                case .running(let port):
                    Label("Running on 127.0.0.1:\(String(port))", systemImage: "circle.fill")
                        .foregroundStyle(Theme.Palette.success)
                        .font(Theme.Font.cardBody)
                case .stopped:
                    Label("Stopped", systemImage: "circle")
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .font(Theme.Font.cardBody)
                case .failed(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.Palette.danger)
                        .font(Theme.Font.cardCaption)
                }
                Spacer()
            }
        }
    }

    private var setupCard: some View {
        DashboardCard(title: "Connect Claude Desktop", systemImage: "link", accent: Theme.Palette.claude) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("One-time setup: add Hyperview to Claude Desktop's MCP config, then restart Claude Desktop.")
                    .font(Theme.Font.cardBody)
                    .foregroundStyle(Theme.Palette.textSecondary)

                Text("1.  Copy this configuration:")
                    .font(Theme.Font.cardBody)
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(mcp.claudeDesktopConfig)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(Theme.Spacing.sm)
                }
                .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.control))

                HStack(spacing: Theme.Spacing.md) {
                    Button(copied ? "Copied ✓" : "Copy Configuration") {
                        #if os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(mcp.claudeDesktopConfig, forType: .string)
                        #endif
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Palette.claude)

                    Button("Open Config Folder") {
                        #if os(macOS)
                        let dir = ("~/Library/Application Support/Claude" as NSString).expandingTildeInPath
                        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
                        #endif
                    }
                }

                Text("2.  Merge it into ~/Library/Application Support/Claude/claude_desktop_config.json (create the file if it doesn't exist).\n3.  Restart Claude Desktop — a \u{201C}hyperview\u{201D} tool server appears.\n4.  Keep Hyperview running; try: \u{201C}What needs my attention today?\u{201D}")
                    .font(Theme.Font.cardCaption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }
}

/// The §7 audit log: every MCP tool invocation.
private struct AuditLogSection: View {
    @Query(sort: \MCPAuditEntry.date, order: .reverse) private var entries: [MCPAuditEntry]
    @Environment(\.modelContext) private var context

    var body: some View {
        DashboardCard(title: "Tool Activity", systemImage: "list.bullet.rectangle", accent: Theme.Palette.claude) {
            if entries.isEmpty {
                EmptyStateLine(text: "No tool calls yet. Once Claude Desktop is connected, every call appears here.")
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(entries.prefix(50)) { entry in
                        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                            Image(systemName: entry.succeeded ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(entry.succeeded ? Theme.Palette.success : Theme.Palette.danger)
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.tool)
                                    .font(Theme.Font.cardBody.weight(.medium))
                                if !entry.detail.isEmpty {
                                    Text(entry.detail)
                                        .font(Theme.Font.cardCaption)
                                        .foregroundStyle(Theme.Palette.textSecondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            Text(entry.date.formatted(date: .omitted, time: .shortened))
                                .font(Theme.Font.cardCaption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                    if entries.count > 5 {
                        Button("Clear Log") {
                            for entry in entries { context.delete(entry) }
                            try? context.save()
                        }
                        .buttonStyle(.plain)
                        .font(Theme.Font.cardCaption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
            }
        }
    }
}
