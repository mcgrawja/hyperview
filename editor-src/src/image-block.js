//
// Resizable image block: @tiptap/extension-image plus a `width` attr (px) and
// a corner drag handle (Jason's request). Width rides in the node attrs, so
// the Swift BlockSerializer persists it with zero changes (image attrs are
// passed through whole).
//

import Image from "@tiptap/extension-image";

export const ResizableImage = Image.extend({
  addAttributes() {
    return {
      ...this.parent?.(),
      width: {
        default: null,
        parseHTML: (element) => {
          const style = element.style && element.style.width;
          return style ? parseInt(style, 10) || null : null;
        },
        renderHTML: (attributes) =>
          attributes.width ? { style: `width: ${attributes.width}px` } : {},
      },
    };
  },

  addNodeView() {
    return ({ node, editor, getPos }) => {
      let current = node;

      const dom = document.createElement("div");
      dom.className = "image-block";

      const img = document.createElement("img");
      img.src = current.attrs.src || "";
      if (current.attrs.alt) img.alt = current.attrs.alt;
      if (current.attrs.width) img.style.width = `${current.attrs.width}px`;

      const handle = document.createElement("div");
      handle.className = "image-resize-handle";
      handle.contentEditable = "false";
      handle.title = "Drag to resize";

      handle.addEventListener("mousedown", (event) => {
        event.preventDefault();
        event.stopPropagation();
        const startX = event.clientX;
        const startWidth = img.getBoundingClientRect().width;
        const maxWidth = dom.parentElement ? dom.parentElement.getBoundingClientRect().width : 2000;

        const onMove = (moveEvent) => {
          const width = Math.round(
            Math.min(maxWidth, Math.max(80, startWidth + (moveEvent.clientX - startX)))
          );
          img.style.width = `${width}px`;
        };
        const onUp = () => {
          document.removeEventListener("mousemove", onMove);
          document.removeEventListener("mouseup", onUp);
          const width = Math.round(img.getBoundingClientRect().width);
          editor
            .chain()
            .command(({ tr }) => {
              tr.setNodeMarkup(getPos(), undefined, { ...current.attrs, width: width });
              return true;
            })
            .run();
        };
        document.addEventListener("mousemove", onMove);
        document.addEventListener("mouseup", onUp);
      });

      dom.appendChild(img);
      dom.appendChild(handle);

      return {
        dom,
        update(updated) {
          if (updated.type.name !== current.type.name) return false;
          current = updated;
          if (img.src !== updated.attrs.src) img.src = updated.attrs.src || "";
          img.style.width = updated.attrs.width ? `${updated.attrs.width}px` : "";
          return true;
        },
      };
    };
  },
});
