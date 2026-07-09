# HYPERVIEW — Project Specification & Claude Code Handoff

**Version:** 0.1 (pre-development)
**Owner:** Jason McGraw
**Purpose of this document:** Single source of truth for architecture decisions, data model, and build order. Drop into the repo root; treat as the operating manual for all Claude Code sessions on this project.

---

## 1. What Hyperview Is

A native macOS (later iOS/iPadOS) SwiftUI application that unifies the Apple ecosystem's personal data — Mail, Calendar, Reminders, Photos, Contacts — behind a single dashboard, replaces Apple Notes with a first-party Notion-lite block-based notes system, and exposes everything to Claude via MCP for life automation.

**Design north star:** Hyperview is the "Home Assistant of personal data." The MCP server is a primary citizen, not an add-on. Every capability is a broker method first; the UI and the MCP tools are both consumers of the broker layer.

---

## 2. Locked Decisions (do not relitigate without owner sign-off)

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | Apple ecosystem only | Non-Apple devices are niche-use; CloudKit becomes viable |
| D2 | Sync via SwiftData + CloudKit (private database) | Free offline-first sync across Mac/iPhone/iPad |
| D3 | No real-time collaboration, ever | Single user; removes the hardest editor/sync problems |
| D4 | Notes = own block-based store ("Notion-lite"), NOT Apple Notes | No public Notes API; owner's Apple Notes are not worth importing |
| D5 | No data imports (Notion already extracted manually; Apple Notes abandoned) | Clean slate |
| D6 | Editor = hybrid: TipTap (or BlockNote) in WKWebView with Swift bridge | Editor is a means, not the project; native rewrite is a someday-item |
| D7 | Databases + relations are POST-v1 features but the v1 schema must support them without migration | CloudKit production schemas are additive-only |
| D8 | Distribution = Developer ID signed, direct install. NOT App Store | Personal app; avoids sandbox fights and review constraints |
| D9 | Mail = own IMAP/SMTP layer (port from owner's prior email client project) + Gmail REST for Gmail accounts | No public API to Mail.app's store |
| D10 | Claude integration is the endgame: in-app Anthropic API + local MCP server | Automation platform, not a chat gimmick |
| D11 | Visual design is PLACEHOLDER (current light-blue/orange mockup). Final scheme comes later via Claude Design | Do not invest in polish; keep all colors/tokens in one theme file for easy swap |

---

## 3. Architecture

```
┌─────────────────────────────────────────────────────┐
│  SwiftUI Shell                                       │
│  Dashboard grid · Module views · Settings            │
│  (all colors/type from Theme.swift — swappable)       │
├─────────────────────────────────────────────────────┤
│  Claude Layer                                        │
│  • In-app: Anthropic Messages API via URLSession      │
│    (key in Keychain; model configurable)              │
│  • MCP Server: local process, stdio + streamable HTTP │
│    exposing broker capabilities as tools               │
├─────────────────────────────────────────────────────┤
│  Broker Layer — one actor per domain                  │
│  EventKitBroker · ContactsBroker · PhotoBroker        │
│  MailBroker · NotesBroker                              │
│  Common protocol: async CRUD + AsyncStream<Change>     │
├─────────────────────────────────────────────────────┤
│  Sources                                             │
│  EventKit · Contacts.framework · PhotoKit              │
│  Network.framework IMAP/SMTP · Gmail REST              │
│  SwiftData + CloudKit (Notes/blocks/databases)          │
└─────────────────────────────────────────────────────┘
```

**Broker protocol sketch:**

```swift
protocol DataBroker: Actor {
    associatedtype Item: Identifiable & Sendable
    func requestAccess() async throws
    func fetch(_ query: BrokerQuery) async throws -> [Item]
    func changes() -> AsyncStream<BrokerChange<Item>>
}
```

Each broker also exposes domain-specific verbs (e.g., `MailBroker.send`, `NotesBroker.appendBlock`). Every public broker verb MUST have a corresponding MCP tool (see §7).

---

## 4. Data Model (SwiftData, CloudKit-backed)

### 4.1 CloudKit/SwiftData hard rules — enforce in every model

- Every stored property has a default value OR is optional
- ALL relationships are optional
- No `#Unique` constraints (CloudKit doesn't support them) — uniqueness is by UUID convention
- No `.deny` delete rules
- Never rename/remove a persisted field after first production schema deploy; deprecate in place instead
- Use fractional/lexicographic sort keys (String) for ordering — never integer reindexing

### 4.2 v1 Active Entities

```swift
@Model final class Note {
    var id: UUID = UUID()
    var title: String = ""
    var emoji: String? = nil
    var folder: Folder? = nil
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    var isArchived: Bool = false
    var sortKey: String = ""              // fractional ordering within folder
    @Relationship(deleteRule: .cascade) var blocks: [Block]? = []
    // Dormant until Databases ship (D7):
    var noteKind: String = "page"          // "page" | "database" — v1 always "page"
    var schemaJSON: Data? = nil            // database property definitions, unused in v1
}

@Model final class Block {
    var id: UUID = UUID()
    var note: Note? = nil
    var parentBlockID: UUID? = nil         // nesting/indent; UUID ref, not relationship
    var sortKey: String = ""
    var kind: String = "paragraph"
    // paragraph | heading1|2|3 | bullet | numbered | todo | quote |
    // code | divider | image | table | callout
    var contentJSON: Data = Data()         // TipTap node JSON for this block
    var isChecked: Bool = false            // todo blocks
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    // Dormant until Databases ship:
    var rowID: UUID? = nil                 // block belongs to a database row
}

@Model final class Folder {
    var id: UUID = UUID()
    var name: String = "Untitled"
    var parentFolderID: UUID? = nil
    var sortKey: String = ""
    var emoji: String? = nil
}

@Model final class Asset {                 // images/files inside notes
    var id: UUID = UUID()
    var noteID: UUID? = nil
    var filename: String = ""
    var mimeType: String = ""
    @Attribute(.externalStorage) var data: Data = Data()
}
```

### 4.3 Dormant Entities — DEFINED in v1, UNUSED until "Hyperview 1.5: Databases"

These exist so CloudKit's production schema already contains them (D7). Do not build UI for them in v1. Do not remove them.

```swift
@Model final class DBProperty {            // column definition on a database Note
    var id: UUID = UUID()
    var databaseNoteID: UUID? = nil
    var name: String = ""
    var kind: String = "text"
    // text | number | select | multiSelect | date | checkbox |
    // url | person | relation | rollup (rollup = 2.0+)
    var configJSON: Data? = nil            // select options, relation target DB id, etc.
    var sortKey: String = ""
}

@Model final class DBRow {
    var id: UUID = UUID()
    var databaseNoteID: UUID? = nil
    var sortKey: String = ""
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    // A row's page content = Blocks with rowID == this id
}

@Model final class DBValue {               // cell
    var id: UUID = UUID()
    var rowID: UUID? = nil
    var propertyID: UUID? = nil
    var valueJSON: Data = Data()
    // relation values = array of target DBRow UUIDs (UUID refs, not
    // SwiftData relationships — Notion-style, MCP-traversable)
}
```

**Relations strategy:** relations are stored as UUID arrays inside `DBValue.valueJSON`. This avoids CloudKit relationship headaches, survives partial syncs, and lets MCP tools resolve links with simple lookups.

---

## 5. Editor (hybrid, D6)

- TipTap (preferred; fall back to BlockNote if TipTap block handling disappoints) running in a `WKWebView`
- Bundle the editor as static local assets (no network dependency)
- Bridge contract via `WKScriptMessageHandler` / `evaluateJavaScript`:

| Direction | Message | Payload |
|-----------|---------|---------|
| Swift → JS | `loadDocument` | full TipTap doc JSON assembled from Blocks |
| JS → Swift | `documentChanged` | debounced (500ms) full doc JSON + per-block dirty list |
| JS → Swift | `blockAction` | `{blockID, action}` for todo-check, etc. |
| Swift → JS | `applyExternalChange` | block-level patch when CloudKit sync updates an open note |
| JS → Swift | `requestAssetUpload` | image paste/drop → Swift stores Asset, returns local URL |

- Serializer: TipTap doc JSON ⇄ `[Block]` mapping lives in one Swift file (`BlockSerializer.swift`) with round-trip unit tests. This is the highest-risk code in the app — test it first.
- Keep muscle-memory features: `/` slash menu, markdown shortcuts (`#`, `-`, `[]`), drag-to-reorder, checklists

---

## 6. Module Notes

- **EventKit (Calendar + Reminders):** request `fullAccessToEvents` / `fullAccessToReminders` lazily on first module open. Subscribe to `EKEventStoreChanged`.
- **Contacts:** `CNContactStore`; fetch keys minimally per view.
- **Photos:** PhotoKit with `PHCachingImageManager`; handle limited-access gracefully; dashboard widget = last-7-days smart fetch, lazy thumbnails.
- **Mail:** port IMAP/SMTP from prior email client project (Network.framework, no third-party SDKs). Gmail via REST for the primary account. Local message cache in SwiftData (NOT CloudKit-synced — mail re-syncs from servers per device).
- **Permissions UX:** stagger TCC prompts per-module on first use; never all at launch.

---

## 7. Claude Layer (the point of the project)

### 7.1 In-app
- Anthropic Messages API, plain URLSession; API key in Keychain; streaming responses
- Dashboard chat panel + contextual actions (summarize mailbox, draft reply, prep-note from calendar event)

### 7.2 MCP Server (primary citizen)
- Local server process launched by the app (menu-bar toggleable), stdio transport for Claude Desktop/Cowork + streamable HTTP on localhost for other clients
- Swift MCP SDK, or a thin Node sidecar if the Swift SDK lags — broker access via a local XPC/HTTP shim either way

**v1 tool inventory (every broker verb gets a tool):**

| Tool | Maps to |
|------|---------|
| `notes_search`, `notes_get`, `notes_create`, `notes_append_blocks`, `notes_update_block`, `notes_toggle_todo` | NotesBroker |
| `calendar_today`, `calendar_query`, `calendar_create_event` | EventKitBroker |
| `reminders_due`, `reminders_create`, `reminders_complete` | EventKitBroker |
| `mail_unread`, `mail_search`, `mail_get_message`, `mail_draft` (draft only; send requires in-app confirm) | MailBroker |
| `contacts_search`, `contacts_get` | ContactsBroker |
| `photos_recent_metadata` | PhotoBroker |
| `dashboard_briefing` | cross-broker "what needs my attention" composite |

**Post-1.5 additions:** `db_query_rows`, `db_create_row`, `db_update_value`, `db_resolve_relations`.

**Safety defaults:** MCP tools are read-heavy by default; mutating tools (send mail, delete anything) require an in-app confirmation surface or are draft-only. Log every MCP tool invocation to an in-app audit view.

---

## 8. Theme (placeholder, D11)

All color/typography in `Theme.swift` as a single token struct. Current placeholder: light blue `#4A90D9` primary, orange `#F58B3C` reserved for Claude/AI surfaces, system SF type. Final scheme arrives from a Claude Design session — nothing outside `Theme.swift` may hardcode a color.

---

## 9. Build Order

| Phase | Deliverable | Notes |
|-------|-------------|-------|
| 0 | Xcode project, entitlements, CloudKit container, Theme.swift, broker protocol | Developer ID signing from day one |
| 1 | EventKit + Contacts brokers → dashboard cards | Fast win; proves the card protocol |
| 2 | Notes core: SwiftData models (ALL of §4, dormant included), folder sidebar, WKWebView editor + bridge + BlockSerializer with tests | Deploy CloudKit schema to production at END of this phase, after model review |
| 3 | Photos broker + dashboard strip | |
| 4 | Mail: port IMAP layer, Gmail REST, three-pane module view | Largest port |
| 5 | Claude in-app chat + contextual actions | |
| 6 | MCP server + v1 tool inventory + audit log | The endgame unlock |
| 1.5 | Databases: UI for DBProperty/DBRow/DBValue, table + board views, relation picker | No migration needed — schema already live |

**Phase-gate rule:** CloudKit schema promotion to production happens exactly once, at end of Phase 2, after a deliberate review of every entity/field. After that, additive-only.

---

## 10. Known Risks

1. **BlockSerializer drift** — TipTap JSON shape vs. Block model. Mitigation: round-trip tests, pin TipTap version, upgrade deliberately.
2. **CloudKit schema regret** — can't remove fields post-production. Mitigation: phase-gate review; prefer `Data`/JSON fields for anything speculative.
3. **SwiftData+CloudKit sync latency/quirks** — merge behavior is opaque. Mitigation: modifiedAt-based UI reconciliation; single-user usage makes conflicts rare.
4. **WKWebView editor jank on iOS** — keyboard/scroll interactions. Mitigation: Mac-first; iOS editor gets its own hardening pass.
5. **Swift MCP SDK maturity** — Mitigation: Node sidecar fallback is pre-approved (D10 spirit: MCP capability matters more than implementation language).
