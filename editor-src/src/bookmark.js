//
// Web bookmark block: "/bookmark" asks for a URL and inserts a card. The page
// title is fetched by Swift (the WKWebView's file origin can't fetch cross-
// origin) via "resolveBookmark" → window.hyperview.deliverBookmark. Clicking
// the card opens the link through the normal openLink routing.
//

import { Node, mergeAttributes } from "@tiptap/core";

function post(msg) {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hyperview) {
    window.webkit.messageHandlers.hyperview.postMessage(msg);
  }
}

export const bookmarkRequests = { pending: {}, counter: 0 };

export function deliverBookmark(ref, title) {
  const apply = bookmarkRequests.pending[ref];
  if (!apply) return;
  delete bookmarkRequests.pending[ref];
  if (title) apply(title);
}

function hostOf(url) {
  try {
    return new URL(url).host.replace(/^www\./, "");
  } catch {
    return url;
  }
}

export const Bookmark = Node.create({
  name: "bookmark",
  group: "block",
  atom: true,
  selectable: true,

  addAttributes() {
    return {
      url: { default: null },
      title: { default: null },
    };
  },

  parseHTML() {
    return [{ tag: "div.bookmark-block" }];
  },

  renderHTML({ node, HTMLAttributes }) {
    return ["div", mergeAttributes(HTMLAttributes, { class: "bookmark-block" }), node.attrs.title || node.attrs.url || ""];
  },

  addNodeView() {
    return ({ node, editor, getPos }) => {
      let current = node;

      const dom = document.createElement("div");
      dom.className = "bookmark-block";

      const icon = document.createElement("span");
      icon.className = "bookmark-icon";
      icon.textContent = "🔗";

      const text = document.createElement("div");
      text.className = "bookmark-text";
      const title = document.createElement("div");
      title.className = "bookmark-title";
      const urlLine = document.createElement("div");
      urlLine.className = "bookmark-url";
      text.appendChild(title);
      text.appendChild(urlLine);

      const sync = (n) => {
        title.textContent = n.attrs.title || hostOf(n.attrs.url || "");
        urlLine.textContent = n.attrs.url || "";
      };
      sync(current);

      dom.appendChild(icon);
      dom.appendChild(text);
      dom.addEventListener("click", (event) => {
        event.preventDefault();
        if (current.attrs.url) post({ type: "openLink", href: current.attrs.url });
      });

      // No title yet → ask Swift to fetch the page's <title>.
      if (current.attrs.url && !current.attrs.title) {
        const ref = `bookmark-${++bookmarkRequests.counter}`;
        bookmarkRequests.pending[ref] = (fetchedTitle) => {
          editor
            .chain()
            .command(({ tr }) => {
              tr.setNodeMarkup(getPos(), undefined, { ...current.attrs, title: fetchedTitle });
              return true;
            })
            .run();
        };
        post({ type: "resolveBookmark", url: current.attrs.url, ref: ref });
      }

      return {
        dom,
        update(updated) {
          if (updated.type.name !== "bookmark") return false;
          current = updated;
          sync(updated);
          return true;
        },
      };
    };
  },

  addCommands() {
    return {
      insertBookmark:
        (url) =>
        ({ chain }) =>
          chain()
            .insertContent({ type: this.name, attrs: { url: url, title: null } })
            .run(),
    };
  },
});

// "/bookmark" prompt: a small centered input (window.prompt is unavailable in
// the WKWebView — modal JS dialogs would wedge the bridge).
export function promptBookmark(editor) {
  const overlay = document.createElement("div");
  overlay.className = "bookmark-prompt";

  const box = document.createElement("div");
  box.className = "bookmark-prompt-box";
  const label = document.createElement("div");
  label.className = "bookmark-prompt-label";
  label.textContent = "Bookmark URL";
  const input = document.createElement("input");
  input.className = "emoji-input";
  input.placeholder = "https://…";

  const finish = (commit) => {
    overlay.remove();
    const value = input.value.trim();
    if (!commit || !value) return;
    const url = value.includes("://") ? value : `https://${value}`;
    editor.commands.insertBookmark(url);
  };

  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter") { event.preventDefault(); finish(true); }
    if (event.key === "Escape") { event.preventDefault(); finish(false); }
  });
  overlay.addEventListener("mousedown", (event) => {
    if (event.target === overlay) finish(false);
  });

  box.appendChild(label);
  box.appendChild(input);
  overlay.appendChild(box);
  document.body.appendChild(overlay);
  input.focus();
}
