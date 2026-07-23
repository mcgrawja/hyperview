//
// Block drag handle (Notion's ⠿): a gutter grip that appears next to the
// hovered top-level block; dragging it moves the whole block. No official
// TipTap extension exists for this outside the Pro registry, so this is a
// small hand-rolled version of the standard ProseMirror pattern: on dragstart,
// select the block as a NodeSelection and hand ProseMirror a `dragging` slice
// with move semantics — the editor's built-in drop logic does the rest.
//

import { Extension } from "@tiptap/core";
import { Plugin, NodeSelection } from "@tiptap/pm/state";

export const DragHandle = Extension.create({
  name: "blockDragHandle",

  addProseMirrorPlugins() {
    return [dragHandlePlugin()];
  },
});

function dragHandlePlugin() {
  let handle = null;
  let hoveredBlock = null; // the top-level block DOM element under the mouse
  let view = null;

  function ensureHandle() {
    if (handle) return handle;
    handle = document.createElement("div");
    handle.className = "drag-handle";
    handle.draggable = true;
    handle.textContent = "⠿";
    handle.style.display = "none";
    document.body.appendChild(handle);

    handle.addEventListener("dragstart", (event) => {
      if (!view || !hoveredBlock) return;
      try {
        const inside = view.posAtDOM(hoveredBlock, 0);
        const $pos = view.state.doc.resolve(inside);
        // Atoms (image/subpage/dbembed) resolve to the position BEFORE the
        // node; text blocks resolve to a position inside — select whichever
        // block the hovered element actually is, at any nesting depth.
        const atomHere = view.state.doc.nodeAt(inside);
        const before = atomHere && atomHere.isBlock && atomHere.isAtom
          ? inside
          : ($pos.depth ? $pos.before($pos.depth) : inside);
        const selection = NodeSelection.create(view.state.doc, before);
        view.dispatch(view.state.tr.setSelection(selection));
        view.dragging = { slice: selection.content(), move: true };
        event.dataTransfer.effectAllowed = "move";
        event.dataTransfer.setData("text/plain", "​");
        event.dataTransfer.setDragImage(hoveredBlock, 0, 0);
      } catch (_error) {
        // A block we can't resolve (rare) — just let the drag die.
        event.preventDefault();
      }
    });

    handle.addEventListener("dragend", () => hide());
    return handle;
  }

  function hide() {
    if (handle) handle.style.display = "none";
    hoveredBlock = null;
  }

  /// The nearest draggable block element containing `target`: a direct child
  /// of the ProseMirror root — or of a column / toggle body / callout body,
  /// so blocks INSIDE those containers get handles too (refinement pass).
  function topLevelBlock(root, target) {
    const isContainer = (el) =>
      el === root
      || (el.classList
        && (el.classList.contains("column")
          || el.classList.contains("toggle-body")
          || el.classList.contains("callout-body")));
    let el = target;
    while (el && el !== root) {
      const parent = el.parentElement;
      if (!parent) return null;
      if (isContainer(parent)) return el;
      el = parent;
    }
    return null;
  }

  function positionHandle(block) {
    const rect = block.getBoundingClientRect();
    const grip = ensureHandle();
    grip.style.display = "block";
    grip.style.top = `${rect.top + 3}px`;
    grip.style.left = `${Math.max(2, rect.left - 26)}px`;
  }

  return new Plugin({
    view(editorView) {
      view = editorView;
      const root = editorView.dom;

      const onMove = (event) => {
        const block = topLevelBlock(root, event.target);
        if (!block) return;
        hoveredBlock = block;
        positionHandle(block);
      };
      const onLeave = (event) => {
        // Leaving the editor for anywhere but the handle itself hides it.
        if (event.relatedTarget && handle && handle.contains(event.relatedTarget)) return;
        hide();
      };
      const onScroll = () => hide();

      root.addEventListener("mousemove", onMove);
      root.addEventListener("mouseleave", onLeave);
      window.addEventListener("scroll", onScroll, true);

      return {
        destroy() {
          root.removeEventListener("mousemove", onMove);
          root.removeEventListener("mouseleave", onLeave);
          window.removeEventListener("scroll", onScroll, true);
          if (handle) {
            handle.remove();
            handle = null;
          }
          view = null;
        },
      };
    },
  });
}
