//
// Page embed (round 5's "synced blocks", honest v1): a live, read-only
// transclusion of another page's content. The node stores only the reference;
// Swift delivers the blocks fresh on every mount (requestPageEmbed →
// deliverPageEmbed), so it always shows the source page's CURRENT content.
// Click the header (or any line) to open the real page and edit there.
//

import { Node, mergeAttributes } from "@tiptap/core";

function post(msg) {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hyperview) {
    window.webkit.messageHandlers.hyperview.postMessage(msg);
  }
}

export const pageEmbedRequests = { pending: {}, counter: 0 };

export function deliverPageEmbed(ref, json) {
  const render = pageEmbedRequests.pending[ref];
  if (!render) return;
  delete pageEmbedRequests.pending[ref];
  render(json ? JSON.parse(json) : null);
}

export const PageEmbed = Node.create({
  name: "pageembed",
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
    return [{ tag: "div.pageembed" }];
  },

  renderHTML({ node, HTMLAttributes }) {
    const label = `${node.attrs.emoji || "📄"} ${node.attrs.title || "Untitled"}`;
    return ["div", mergeAttributes(HTMLAttributes, { class: "pageembed" }), label];
  },

  addNodeView() {
    return ({ node }) => {
      const dom = document.createElement("div");
      dom.className = "pageembed";

      const open = () => {
        if (node.attrs.noteID) {
          post({ type: "openLink", href: `hyperview://note/${node.attrs.noteID}` });
        }
      };

      const header = document.createElement("div");
      header.className = "pageembed-header";
      header.textContent = `${node.attrs.emoji || "📄"} ${node.attrs.title || "Untitled"}`;
      header.title = "Open page";
      header.addEventListener("click", (event) => {
        event.preventDefault();
        open();
      });

      const body = document.createElement("div");
      body.className = "pageembed-body";
      body.textContent = "Loading…";

      dom.appendChild(header);
      dom.appendChild(body);

      if (node.attrs.noteID) {
        const ref = `pageembed-${++pageEmbedRequests.counter}`;
        pageEmbedRequests.pending[ref] = (snapshot) => {
          body.innerHTML = "";
          if (!snapshot) {
            body.textContent = "Page not found (deleted?).";
            return;
          }
          for (const line of snapshot.lines || []) {
            const row = document.createElement("div");
            row.className = `pageembed-line kind-${line.kind || "paragraph"}`;
            let prefix = "";
            if (line.kind === "bullet" || line.kind === "numbered") prefix = "• ";
            if (line.kind === "todo") prefix = line.checked ? "☑ " : "☐ ";
            row.textContent = prefix + (line.text || "");
            row.addEventListener("click", open);
            body.appendChild(row);
          }
          if (snapshot.more > 0) {
            const more = document.createElement("div");
            more.className = "pageembed-more";
            more.textContent = `+ ${snapshot.more} more — open the page`;
            more.addEventListener("click", open);
            body.appendChild(more);
          }
          if ((snapshot.lines || []).length === 0) {
            body.textContent = "Empty page.";
          }
        };
        post({ type: "requestPageEmbed", noteID: node.attrs.noteID, ref: ref });
      } else {
        body.textContent = "No page selected.";
      }

      return {
        dom,
        ignoreMutation() {
          return true;
        },
      };
    };
  },
});
