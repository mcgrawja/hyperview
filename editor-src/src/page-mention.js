//
// Page mentions: type "@" to link a page inline as a chip. The chip is an
// inline ATOM node — its attrs (noteID/title/emoji) live inside the paragraph's
// content array, so Swift's BlockSerializer round-trips it with zero changes;
// Swift refreshes the cached title/emoji on every load so renames propagate.
//
// The page list comes from Swift (window.hyperview.setPages) — the editor
// never queries storage itself.
//

import { Node, Extension, mergeAttributes } from "@tiptap/core";
import Suggestion from "@tiptap/suggestion";
import { PluginKey } from "@tiptap/pm/state";
import { CommandMenu } from "./slash-menu.js";

function post(msg) {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hyperview) {
    window.webkit.messageHandlers.hyperview.postMessage(msg);
  }
}

// Populated by Swift via window.hyperview.setPages([{id,title,emoji}, …]) and
// setMentionSources([{kind,id,title,icon,dateISO?}, …]) — contacts, events,
// reminders (integration round 2).
export const pageIndex = { pages: [], sources: [] };

export const PageMention = Node.create({
  name: "pageMention",
  group: "inline",
  inline: true,
  atom: true,
  selectable: true,

  addAttributes() {
    return {
      noteID: { default: null },
      title: { default: "Untitled" },
      emoji: { default: null },
      // "page" | "contact" | "event" | "reminder" — non-page chips route
      // through openMention instead of the note link path.
      refKind: { default: "page" },
      dateISO: { default: null },
    };
  },

  parseHTML() {
    return [{ tag: "span.page-mention" }];
  },

  renderHTML({ node, HTMLAttributes }) {
    const label = `${node.attrs.emoji || "📄"} ${node.attrs.title || "Untitled"}`;
    return ["span", mergeAttributes(HTMLAttributes, { class: "page-mention" }), label];
  },

  addNodeView() {
    return ({ node }) => {
      const dom = document.createElement("span");
      dom.className = "page-mention";
      dom.textContent = `${node.attrs.emoji || "📄"} ${node.attrs.title || "Untitled"}`;
      dom.addEventListener("click", (event) => {
        event.preventDefault();
        if (!node.attrs.noteID) return;
        if ((node.attrs.refKind || "page") === "page") {
          post({ type: "openLink", href: `hyperview://note/${node.attrs.noteID}` });
        } else {
          post({
            type: "openMention",
            kind: node.attrs.refKind,
            id: node.attrs.noteID,
            dateISO: node.attrs.dateISO || null,
          });
        }
      });
      return {
        dom,
        update(updated) {
          if (updated.type.name !== "pageMention") return false;
          dom.textContent = `${updated.attrs.emoji || "📄"} ${updated.attrs.title || "Untitled"}`;
          node = updated;
          return true;
        },
      };
    };
  },
});

export const PageMentionSuggestion = Extension.create({
  name: "pageMentionSuggestion",

  addProseMirrorPlugins() {
    let menu = null;
    return [
      Suggestion({
        editor: this.editor,
        // Distinct from the slash menu's key — see the note there.
        pluginKey: new PluginKey("pageMentionSuggestion"),
        char: "@",
        allowSpaces: false,
        items: ({ query }) => {
          const q = query.toLowerCase();
          const insert = (editor, range, attrs) =>
            editor
              .chain()
              .focus()
              .deleteRange(range)
              .insertContent([
                { type: "pageMention", attrs: attrs },
                { type: "text", text: " " },
              ])
              .run();

          const pages = pageIndex.pages
            .filter((page) => (page.title || "Untitled").toLowerCase().includes(q))
            .slice(0, 6)
            .map((page) => ({
              title: `${page.emoji || "📄"} ${page.title || "Untitled"}`,
              hint: "Page",
              run: (editor, range) =>
                insert(editor, range, {
                  noteID: page.id, title: page.title, emoji: page.emoji || null, refKind: "page",
                }),
            }));

          const kindLabel = { contact: "Contact", event: "Event", reminder: "Reminder" };
          const sources = pageIndex.sources
            .filter((item) => (item.title || "").toLowerCase().includes(q))
            .slice(0, q ? 9 : 3) // an empty "@" leads with pages
            .map((item) => ({
              title: `${item.icon || "🔗"} ${item.title}`,
              hint: kindLabel[item.kind] || item.kind,
              run: (editor, range) =>
                insert(editor, range, {
                  noteID: item.id,
                  title: item.title,
                  emoji: item.icon || null,
                  refKind: item.kind,
                  dateISO: item.dateISO || null,
                }),
            }));

          return pages.concat(sources);
        },
        command: ({ editor, range, props }) => props.run(editor, range),
        render: () => ({
          onStart: (props) => {
            menu = new CommandMenu();
            menu.selected = 0;
            menu.update(props);
          },
          onUpdate: (props) => menu && menu.update(props),
          onKeyDown: (props) => (menu ? menu.onKeyDown(props.event) : false),
          onExit: () => {
            if (menu) { menu.destroy(); menu = null; }
          },
        }),
      }),
    ];
  },
});
