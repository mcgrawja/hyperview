//
// Inline database block (Phase 4): a read-only preview of a database view
// embedded in the document flow. The node stores only the reference
// {noteID (database note), viewID, cached title/emoji}; on every mount the
// nodeView asks Swift for a fresh snapshot (columns + display-formatted rows
// with the view's filters/sorts applied) — the data itself never enters the
// block JSON. Clicking the header opens the real database.
//

import { Node, mergeAttributes } from "@tiptap/core";

function post(msg) {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hyperview) {
    window.webkit.messageHandlers.hyperview.postMessage(msg);
  }
}

// ref → render callback for in-flight snapshot requests.
export const dbEmbedRequests = { pending: {}, counter: 0 };

export function deliverDBEmbed(ref, snapshotJSON) {
  const render = dbEmbedRequests.pending[ref];
  if (!render) return;
  delete dbEmbedRequests.pending[ref];
  render(snapshotJSON ? JSON.parse(snapshotJSON) : null);
}

export const DBEmbed = Node.create({
  name: "dbembed",
  group: "block",
  atom: true,
  selectable: true,

  addAttributes() {
    return {
      noteID: { default: null },
      viewID: { default: null },
      title: { default: "Untitled" },
      emoji: { default: null },
    };
  },

  parseHTML() {
    return [{ tag: "div.dbembed" }];
  },

  renderHTML({ node, HTMLAttributes }) {
    const label = `${node.attrs.emoji || "📊"} ${node.attrs.title || "Untitled"}`;
    return ["div", mergeAttributes(HTMLAttributes, { class: "dbembed" }), label];
  },

  addNodeView() {
    return ({ node }) => {
      const dom = document.createElement("div");
      dom.className = "dbembed";

      const header = document.createElement("div");
      header.className = "dbembed-header";
      header.textContent = `${node.attrs.emoji || "📊"} ${node.attrs.title || "Untitled"}`;
      header.title = "Open database";
      header.addEventListener("click", (event) => {
        event.preventDefault();
        if (node.attrs.noteID) {
          post({ type: "openLink", href: `hyperview://note/${node.attrs.noteID}` });
        }
      });

      const body = document.createElement("div");
      body.className = "dbembed-body";
      body.textContent = "Loading…";

      dom.appendChild(header);
      dom.appendChild(body);

      if (node.attrs.noteID) {
        const ref = `dbembed-${++dbEmbedRequests.counter}`;
        dbEmbedRequests.pending[ref] = (snapshot) => renderSnapshot(header, body, node, snapshot);
        post({
          type: "requestDBEmbed",
          databaseID: node.attrs.noteID,
          viewID: node.attrs.viewID || null,
          ref: ref,
        });
      } else {
        body.textContent = "No database selected.";
      }

      return { dom };
    };
  },
});

function renderSnapshot(header, body, node, snapshot) {
  if (!snapshot) {
    body.textContent = "Database not found (deleted?). Click to try opening it.";
    return;
  }
  const viewSuffix = snapshot.view ? ` · ${snapshot.view}` : "";
  header.textContent = `${snapshot.emoji || "📊"} ${snapshot.title}${viewSuffix}`;

  body.innerHTML = "";
  const table = document.createElement("table");
  table.className = "dbembed-table";

  const head = document.createElement("tr");
  for (const column of snapshot.columns || []) {
    const th = document.createElement("th");
    th.textContent = column;
    head.appendChild(th);
  }
  table.appendChild(head);

  for (const row of snapshot.rows || []) {
    const tr = document.createElement("tr");
    for (const cell of row) {
      const td = document.createElement("td");
      td.textContent = cell;
      tr.appendChild(td);
    }
    table.appendChild(tr);
  }
  body.appendChild(table);

  if ((snapshot.rows || []).length === 0) {
    const empty = document.createElement("div");
    empty.className = "dbembed-more";
    empty.textContent = "No rows match this view.";
    body.appendChild(empty);
  } else if (snapshot.more > 0) {
    const more = document.createElement("div");
    more.className = "dbembed-more";
    more.textContent = `+ ${snapshot.more} more`;
    body.appendChild(more);
  }
}
