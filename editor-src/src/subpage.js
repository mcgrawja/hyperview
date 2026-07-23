//
// Sub-page block (Notion's inline child page): a full-width row in the
// document flow that opens the page on click. Block-level ATOM node — Swift
// stores it as kind .subpage with the attrs (noteID + cached title/emoji,
// refreshed on every load).
//
// Created by the "/Sub-page" slash command: Swift makes the child page and
// calls window.hyperview.insertSubpage(id, title, emoji).
//

import { Node, mergeAttributes } from "@tiptap/core";

function post(msg) {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hyperview) {
    window.webkit.messageHandlers.hyperview.postMessage(msg);
  }
}

export const Subpage = Node.create({
  name: "subpage",
  group: "block",
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
    return [{ tag: "div.subpage-block" }];
  },

  renderHTML({ node, HTMLAttributes }) {
    const label = `${node.attrs.emoji || "📄"} ${node.attrs.title || "Untitled"}`;
    return ["div", mergeAttributes(HTMLAttributes, { class: "subpage-block" }), label];
  },

  addNodeView() {
    return ({ node }) => {
      const dom = document.createElement("div");
      dom.className = "subpage-block";
      const icon = document.createElement("span");
      icon.className = "subpage-icon";
      const title = document.createElement("span");
      title.className = "subpage-title";
      const sync = (n) => {
        icon.textContent = n.attrs.emoji || "📄";
        title.textContent = n.attrs.title || "Untitled";
      };
      sync(node);
      dom.appendChild(icon);
      dom.appendChild(title);
      dom.addEventListener("click", (event) => {
        event.preventDefault();
        if (node.attrs.noteID) {
          post({ type: "openLink", href: `hyperview://note/${node.attrs.noteID}` });
        }
      });
      return {
        dom,
        update(updated) {
          if (updated.type.name !== "subpage") return false;
          sync(updated);
          node = updated;
          return true;
        },
      };
    };
  },
});
