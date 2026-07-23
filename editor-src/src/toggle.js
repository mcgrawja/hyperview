//
// Toggle block (Notion-style collapsible): a summary line + a body of blocks,
// folded by a chevron. Three nodes, details/summary-shaped:
//
//   toggle (attrs.open) → toggleSummary (inline*) + toggleBody (block+)
//
// Serialized as ONE Swift block: {type:"toggle", attrs:{open}, content:
// [toggleSummary, toggleBody]} — BlockSerializer passes the pair through
// (kind .toggle), so the whole subtree round-trips losslessly. `open` being
// an attr means the fold state syncs with the note; acceptable (it's content
// state, like a todo's checkbox).
//

import { Node } from "@tiptap/core";

export const ToggleSummary = Node.create({
  name: "toggleSummary",
  content: "inline*",
  defining: true,

  parseHTML() {
    return [{ tag: "div.toggle-summary" }];
  },

  renderHTML() {
    return ["div", { class: "toggle-summary" }, 0];
  },
});

export const ToggleBody = Node.create({
  name: "toggleBody",
  content: "block+",
  defining: true,

  parseHTML() {
    return [{ tag: "div.toggle-body" }];
  },

  renderHTML() {
    return ["div", { class: "toggle-body" }, 0];
  },
});

export const Toggle = Node.create({
  name: "toggle",
  group: "block",
  content: "toggleSummary toggleBody",
  defining: true,

  addAttributes() {
    return { open: { default: true } };
  },

  parseHTML() {
    return [{ tag: "div.toggle" }];
  },

  renderHTML({ node }) {
    return ["div", { class: "toggle" + (node.attrs.open ? " open" : "") }, ["div", { class: "toggle-inner" }, 0]];
  },

  addNodeView() {
    return ({ node, editor, getPos }) => {
      let current = node;

      const dom = document.createElement("div");
      dom.className = "toggle" + (current.attrs.open ? " open" : "");

      const chevron = document.createElement("button");
      chevron.className = "toggle-chevron";
      chevron.type = "button";
      chevron.contentEditable = "false";
      chevron.title = "Expand / collapse";
      chevron.addEventListener("mousedown", (event) => {
        event.preventDefault();
        editor
          .chain()
          .command(({ tr }) => {
            tr.setNodeMarkup(getPos(), undefined, { ...current.attrs, open: !current.attrs.open });
            return true;
          })
          .run();
      });

      const inner = document.createElement("div");
      inner.className = "toggle-inner";

      dom.appendChild(chevron);
      dom.appendChild(inner);

      return {
        dom,
        contentDOM: inner,
        update(updated) {
          if (updated.type.name !== "toggle") return false;
          current = updated;
          dom.className = "toggle" + (updated.attrs.open ? " open" : "");
          return true;
        },
      };
    };
  },

  addCommands() {
    return {
      setToggle:
        () =>
        ({ chain }) =>
          chain()
            .insertContent({
              type: this.name,
              attrs: { open: true },
              content: [
                { type: "toggleSummary" },
                { type: "toggleBody", content: [{ type: "paragraph" }] },
              ],
            })
            .run(),
    };
  },

  // Keyboard flow (refinement pass): Enter on the summary jumps INTO the body
  // (opening a closed toggle on the way); Cmd-Enter folds/unfolds from
  // anywhere inside the toggle.
  addKeyboardShortcuts() {
    const summaryEnter = () => {
      const { state } = this.editor;
      const { $from, empty } = state.selection;
      if (!empty || $from.parent.type.name !== "toggleSummary") return false;
      const summaryDepth = $from.depth;
      const toggleDepth = summaryDepth - 1;
      if (toggleDepth < 1 || $from.node(toggleDepth).type.name !== "toggle") return false;
      const toggle = $from.node(toggleDepth);
      const togglePos = $from.before(toggleDepth);
      // after(summary) + 1 enters the body, + 1 enters its first block.
      const target = $from.after(summaryDepth) + 2;
      return this.editor
        .chain()
        .command(({ tr }) => {
          if (!toggle.attrs.open) {
            tr.setNodeMarkup(togglePos, undefined, { ...toggle.attrs, open: true });
          }
          return true;
        })
        .setTextSelection(target)
        .run();
    };

    const foldToggle = () => {
      const { $from } = this.editor.state.selection;
      for (let depth = $from.depth; depth >= 1; depth--) {
        const node = $from.node(depth);
        if (node.type.name !== "toggle") continue;
        const pos = $from.before(depth);
        return this.editor
          .chain()
          .command(({ tr }) => {
            tr.setNodeMarkup(pos, undefined, { ...node.attrs, open: !node.attrs.open });
            return true;
          })
          .run();
      }
      return false;
    };

    return {
      Enter: summaryEnter,
      "Mod-Enter": foldToggle,
    };
  },
});
