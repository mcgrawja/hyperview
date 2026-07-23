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

// Populated by Swift via window.hyperview.setPages([{id,title,emoji}, …]).
export const pageIndex = { pages: [] };

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
        if (node.attrs.noteID) {
          post({ type: "openLink", href: `hyperview://note/${node.attrs.noteID}` });
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
          return pageIndex.pages
            .filter((page) => (page.title || "Untitled").toLowerCase().includes(q))
            .slice(0, 8)
            .map((page) => ({
              title: `${page.emoji || "📄"} ${page.title || "Untitled"}`,
              hint: "Link page",
              page: page,
              run: (editor, range) =>
                editor
                  .chain()
                  .focus()
                  .deleteRange(range)
                  .insertContent([
                    {
                      type: "pageMention",
                      attrs: { noteID: page.id, title: page.title, emoji: page.emoji || null },
                    },
                    { type: "text", text: " " },
                  ])
                  .run(),
            }));
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
