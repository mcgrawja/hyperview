//
// Callout block (Notion-style): an emoji badge + rich paragraphs on a tinted
// panel. The emoji is a node attr; clicking it cycles a small palette.
// Serialized as {type:"callout", attrs:{emoji}, content:[paragraph…]} — the
// Swift BlockSerializer passes attrs+content through (kind .callout).
//

import { Node, mergeAttributes } from "@tiptap/core";

const EMOJIS = ["💡", "⚠️", "📌", "✅", "❓", "🔥", "💭", "🚧"];

export const Callout = Node.create({
  name: "callout",
  group: "block",
  content: "paragraph+",
  defining: true,

  addAttributes() {
    return { emoji: { default: "💡" } };
  },

  parseHTML() {
    return [{ tag: "div.callout" }];
  },

  renderHTML({ HTMLAttributes }) {
    return ["div", mergeAttributes(HTMLAttributes, { class: "callout" }), ["div", { class: "callout-body" }, 0]];
  },

  addNodeView() {
    return ({ node, editor, getPos }) => {
      let current = node;

      const dom = document.createElement("div");
      dom.className = "callout";

      const emoji = document.createElement("button");
      emoji.className = "callout-emoji";
      emoji.type = "button";
      emoji.contentEditable = "false";
      emoji.textContent = current.attrs.emoji;
      emoji.title = "Change emoji";
      emoji.addEventListener("mousedown", (event) => {
        event.preventDefault();
        const index = EMOJIS.indexOf(current.attrs.emoji);
        const next = EMOJIS[(index + 1 + EMOJIS.length) % EMOJIS.length] || EMOJIS[0];
        editor
          .chain()
          .command(({ tr }) => {
            tr.setNodeMarkup(getPos(), undefined, { ...current.attrs, emoji: next });
            return true;
          })
          .run();
      });

      const body = document.createElement("div");
      body.className = "callout-body";

      dom.appendChild(emoji);
      dom.appendChild(body);

      return {
        dom,
        contentDOM: body,
        update(updated) {
          if (updated.type.name !== "callout") return false;
          current = updated;
          emoji.textContent = updated.attrs.emoji;
          return true;
        },
      };
    };
  },

  addCommands() {
    return {
      setCallout:
        () =>
        ({ commands }) =>
          commands.wrapIn(this.name),
    };
  },
});
