//
// Code block with syntax highlighting (lowlight/highlight.js "common" grammar
// set) and a Notion-style language picker in the top-right corner. The chosen
// language lives in the node's `language` attr — exactly what the Swift
// BlockSerializer already stores for kind .code.
//

import CodeBlockLowlight from "@tiptap/extension-code-block-lowlight";
import { createLowlight, common } from "lowlight";

const lowlight = createLowlight(common);

export const CodeBlock = CodeBlockLowlight.extend({
  addNodeView() {
    return ({ node, editor, getPos }) => {
      let current = node;

      const dom = document.createElement("pre");
      dom.className = "code-block";

      const select = document.createElement("select");
      select.className = "code-lang";
      select.contentEditable = "false";
      const auto = document.createElement("option");
      auto.value = "";
      auto.textContent = "auto";
      select.appendChild(auto);
      for (const language of lowlight.listLanguages().sort()) {
        const option = document.createElement("option");
        option.value = language;
        option.textContent = language;
        select.appendChild(option);
      }
      select.value = current.attrs.language || "";
      // Keep clicks in the picker from moving the text cursor.
      select.addEventListener("mousedown", (event) => event.stopPropagation());
      select.addEventListener("change", () => {
        editor
          .chain()
          .command(({ tr }) => {
            tr.setNodeMarkup(getPos(), undefined, { ...current.attrs, language: select.value || null });
            return true;
          })
          .run();
      });

      const code = document.createElement("code");

      dom.appendChild(select);
      dom.appendChild(code);

      return {
        dom,
        contentDOM: code,
        update(updated) {
          if (updated.type.name !== current.type.name) return false;
          current = updated;
          select.value = updated.attrs.language || "";
          return true;
        },
      };
    };
  },
}).configure({ lowlight });
