//
// Column layout (Phase 5, the trial-and-error one): a columnList block holding
// 2–4 columns, each a full block container (paragraphs, lists, callouts,
// embeds — anything). Serialized as ONE Swift block (kind .columns, content
// passthrough), like tables and toggles.
//
// Known v1 roughness (accepted): no drag-to-resize widths (equal flex), no
// drag handle on blocks INSIDE columns (they're not top-level), and deleting
// all content of a column can require deleting the column list via its own
// drag handle / selection.
//

import { Node } from "@tiptap/core";

export const Column = Node.create({
  name: "column",
  content: "block+",
  defining: true,
  isolating: true,

  parseHTML() {
    return [{ tag: "div.column" }];
  },

  renderHTML() {
    return ["div", { class: "column" }, 0];
  },
});

export const ColumnList = Node.create({
  name: "columnList",
  group: "block",
  content: "column{2,4}",
  defining: true,

  parseHTML() {
    return [{ tag: "div.column-list" }];
  },

  renderHTML() {
    return ["div", { class: "column-list" }, 0];
  },

  addCommands() {
    return {
      setColumns:
        (count) =>
        ({ chain }) => {
          const columns = [];
          for (let i = 0; i < count; i++) {
            columns.push({ type: "column", content: [{ type: "paragraph" }] });
          }
          return chain()
            .insertContent({ type: this.name, content: columns })
            .run();
        },
    };
  },
});
