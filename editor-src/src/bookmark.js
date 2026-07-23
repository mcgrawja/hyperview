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

      // ✎ fixes a mistyped URL in place (Jason's request): reopens the
      // prompt pre-filled; committing rewrites the url and re-resolves.
      const edit = document.createElement("button");
      edit.type = "button";
      edit.className = "bookmark-edit";
      edit.contentEditable = "false";
      edit.textContent = "✎";
      edit.title = "Edit URL";
      edit.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        promptBookmark(editor, {
          title: "Edit bookmark URL",
          initial: current.attrs.url || "",
          onSubmit: (url) => {
            editor
              .chain()
              .command(({ tr }) => {
                tr.setNodeMarkup(getPos(), undefined, { url: url, title: null });
                return true;
              })
              .run();
          },
        });
      });

      dom.appendChild(icon);
      dom.appendChild(text);
      dom.appendChild(edit);
      dom.addEventListener("click", (event) => {
        event.preventDefault();
        if (current.attrs.url) post({ type: "openLink", href: current.attrs.url });
      });

      // Fetch the page's <title> whenever the url has none (fresh insert OR
      // an edited url — update() re-triggers this).
      let requestedURL = null;
      const resolveIfNeeded = () => {
        if (!current.attrs.url || current.attrs.title || requestedURL === current.attrs.url) return;
        requestedURL = current.attrs.url;
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
      };
      resolveIfNeeded();

      return {
        dom,
        update(updated) {
          if (updated.type.name !== "bookmark") return false;
          current = updated;
          sync(updated);
          resolveIfNeeded();
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
// the WKWebView — modal JS dialogs would wedge the bridge). options.initial
// pre-fills; options.onSubmit overrides the default insert (the edit path).
export function promptBookmark(editor, options = {}) {
  const overlay = document.createElement("div");
  overlay.className = "bookmark-prompt";

  const box = document.createElement("div");
  box.className = "bookmark-prompt-box";
  const label = document.createElement("div");
  label.className = "bookmark-prompt-label";
  label.textContent = options.title || "Bookmark URL";
  const input = document.createElement("input");
  input.className = "emoji-input";
  input.placeholder = "https://…";
  if (options.initial) input.value = options.initial;

  const finish = (commit) => {
    overlay.remove();
    const value = input.value.trim();
    if (!commit || !value) return;
    const url = value.includes("://") ? value : `https://${value}`;
    if (options.onSubmit) {
      options.onSubmit(url);
    } else {
      editor.commands.insertBookmark(url);
    }
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
