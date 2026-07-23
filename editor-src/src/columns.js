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

  addAttributes() {
    return {
      // Percent widths as a comma string ("30,70") — a STRING deliberately:
      // Swift's PMValue attr codec handles scalars only, an array would be
      // dropped in round-trip. null = equal columns.
      widths: { default: null },
    };
  },

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

  // NodeView so widths apply to the column children and the gaps between
  // columns are draggable resize grips (refinement pass).
  addNodeView() {
    return ({ node, editor, getPos }) => {
      let current = node;

      const dom = document.createElement("div");
      dom.className = "column-list";

      const columnsOf = () => Array.from(dom.children).filter((el) => el.classList.contains("column"));

      const applyWidths = () => {
        const children = columnsOf();
        const parsed = (current.attrs.widths || "")
          .split(",")
          .map((part) => parseFloat(part))
          .filter((part) => !Number.isNaN(part) && part > 0);
        children.forEach((el, index) => {
          if (parsed.length === children.length) {
            el.style.flex = `0 0 calc(${parsed[index]}% - 14px)`;
          } else {
            el.style.flex = "1 1 0px";
          }
        });
      };

      // Gap under the pointer → the column pair it separates, or null.
      const gapAt = (clientX) => {
        const children = columnsOf();
        for (let i = 0; i < children.length - 1; i++) {
          const leftRect = children[i].getBoundingClientRect();
          const rightRect = children[i + 1].getBoundingClientRect();
          if (clientX >= leftRect.right - 3 && clientX <= rightRect.left + 3) {
            return { index: i, left: children[i], right: children[i + 1] };
          }
        }
        return null;
      };

      dom.addEventListener("mousemove", (event) => {
        dom.style.cursor = gapAt(event.clientX) ? "col-resize" : "";
      });

      dom.addEventListener("mousedown", (event) => {
        const gap = gapAt(event.clientX);
        if (!gap) return;
        event.preventDefault();
        event.stopPropagation();

        const startX = event.clientX;
        const leftStart = gap.left.getBoundingClientRect().width;
        const rightStart = gap.right.getBoundingClientRect().width;
        const pairTotal = leftStart + rightStart;

        const onMove = (moveEvent) => {
          const delta = Math.min(
            rightStart - 60,
            Math.max(60 - leftStart, moveEvent.clientX - startX)
          );
          gap.left.style.flex = `0 0 ${leftStart + delta}px`;
          gap.right.style.flex = `0 0 ${rightStart - delta}px`;
        };
        const onUp = () => {
          document.removeEventListener("mousemove", onMove);
          document.removeEventListener("mouseup", onUp);
          // Commit every column's share of the row as percents.
          const children = columnsOf();
          const total = children.reduce((sum, el) => sum + el.getBoundingClientRect().width, 0);
          const widths = children
            .map((el) => ((el.getBoundingClientRect().width / Math.max(total, 1)) * 100).toFixed(1))
            .join(",");
          editor
            .chain()
            .command(({ tr }) => {
              tr.setNodeMarkup(getPos(), undefined, { ...current.attrs, widths: widths });
              return true;
            })
            .run();
          void pairTotal;
        };
        document.addEventListener("mousemove", onMove);
        document.addEventListener("mouseup", onUp);
      });

      // Late apply: PM fills contentDOM after the nodeView returns.
      setTimeout(applyWidths, 0);

      return {
        dom,
        contentDOM: dom,
        update(updated) {
          if (updated.type.name !== "columnList") return false;
          current = updated;
          setTimeout(applyWidths, 0);
          return true;
        },
      };
    };
  },
});
