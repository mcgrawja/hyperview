//
// Inline database block — EDITABLE since the embeds round. The node stores
// only the reference {noteID (database note), viewID, cached title/emoji}; on
// mount the nodeView asks Swift for a snapshot that now carries column
// metadata (kind, select options, relation targets) and raw cell values, so
// the embed renders real inputs and writes back through the bridge
// ("dbSetCell" / "dbAddRowEmbed"). After any write, Swift calls
// refreshDBEmbeds(databaseID) and every embed of that database re-requests
// its snapshot — multiple embeds of one database stay consistent.
//
// The ↗ on a row opens the row's page natively ("openDBRow").
//

import { Node, mergeAttributes } from "@tiptap/core";

function post(msg) {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hyperview) {
    window.webkit.messageHandlers.hyperview.postMessage(msg);
  }
}

// ref → pending render callback; databaseID → live embeds (for refresh).
export const dbEmbedRequests = { pending: {}, counter: 0, mounted: new Map() };

export function deliverDBEmbed(ref, snapshotJSON) {
  const render = dbEmbedRequests.pending[ref];
  if (!render) return;
  delete dbEmbedRequests.pending[ref];
  render(snapshotJSON ? JSON.parse(snapshotJSON) : null);
}

export function refreshDBEmbeds(databaseID) {
  for (const entry of dbEmbedRequests.mounted.values()) {
    if (entry.databaseID === databaseID) entry.request();
  }
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

      const mountKey = `dbembed-mount-${++dbEmbedRequests.counter}`;
      const request = () => {
        if (!node.attrs.noteID) {
          body.textContent = "No database selected.";
          return;
        }
        const ref = `dbembed-${++dbEmbedRequests.counter}`;
        dbEmbedRequests.pending[ref] = (snapshot) => renderSnapshot(header, body, node, snapshot);
        post({
          type: "requestDBEmbed",
          databaseID: node.attrs.noteID,
          viewID: node.attrs.viewID || null,
          ref: ref,
        });
      };
      dbEmbedRequests.mounted.set(mountKey, { databaseID: node.attrs.noteID, request });
      request();

      return {
        dom,
        // The embed's inputs/popups own their events — ProseMirror must not
        // treat clicks/keys inside the body as document edits.
        stopEvent(event) {
          return body.contains(event.target);
        },
        ignoreMutation() {
          return true;
        },
        destroy() {
          dbEmbedRequests.mounted.delete(mountKey);
        },
      };
    };
  },
});

// MARK: rendering

function renderSnapshot(header, body, node, snapshot) {
  if (!snapshot) {
    body.textContent = "Database not found (deleted?). Click the header to try opening it.";
    return;
  }
  const viewSuffix = snapshot.view ? ` · ${snapshot.view}` : "";
  header.textContent = `${snapshot.emoji || "📊"} ${snapshot.title}${viewSuffix}`;

  body.innerHTML = "";
  const table = document.createElement("table");
  table.className = "dbembed-table";

  const head = document.createElement("tr");
  const openTh = document.createElement("th");
  openTh.className = "dbembed-open-col";
  head.appendChild(openTh);
  for (const column of snapshot.columns || []) {
    const th = document.createElement("th");
    th.textContent = column.name;
    head.appendChild(th);
  }
  table.appendChild(head);

  for (const row of snapshot.rows || []) {
    table.appendChild(renderRow(node, snapshot, row));
  }
  body.appendChild(table);

  const footer = document.createElement("div");
  footer.className = "dbembed-footer";
  const addButton = document.createElement("button");
  addButton.type = "button";
  addButton.className = "dbembed-add";
  addButton.textContent = "+ New";
  addButton.addEventListener("click", () => {
    post({ type: "dbAddRowEmbed", databaseID: node.attrs.noteID, viewID: node.attrs.viewID || null });
  });
  footer.appendChild(addButton);
  if ((snapshot.rows || []).length === 0) {
    const empty = document.createElement("span");
    empty.className = "dbembed-more";
    empty.textContent = "No rows match this view.";
    footer.appendChild(empty);
  } else if (snapshot.more > 0) {
    const more = document.createElement("span");
    more.className = "dbembed-more";
    more.textContent = `+ ${snapshot.more} more in the database`;
    footer.appendChild(more);
  }
  body.appendChild(footer);
}

function renderRow(node, snapshot, row) {
  const tr = document.createElement("tr");

  const openTd = document.createElement("td");
  openTd.className = "dbembed-open-col";
  const openButton = document.createElement("button");
  openButton.type = "button";
  openButton.className = "dbembed-open";
  openButton.textContent = "↗";
  openButton.title = "Open as page";
  openButton.addEventListener("click", () => {
    post({ type: "openDBRow", databaseID: node.attrs.noteID, rowID: row.id });
  });
  openTd.appendChild(openButton);
  tr.appendChild(openTd);

  for (const column of snapshot.columns || []) {
    const td = document.createElement("td");
    const cell = (row.cells || {})[column.id] || { display: "", raw: null };
    td.appendChild(cellEditor(node, column, row, cell));
    tr.appendChild(td);
  }
  return tr;
}

function commit(node, row, column, value) {
  post({
    type: "dbSetCell",
    databaseID: node.attrs.noteID,
    rowID: row.id,
    propertyID: column.id,
    value: value,
  });
}

// MARK: per-kind cell editors

function cellEditor(node, column, row, cell) {
  switch (column.kind) {
    case "checkbox": {
      const input = document.createElement("input");
      input.type = "checkbox";
      input.className = "dbembed-check";
      input.checked = cell.raw === true;
      input.addEventListener("change", () => commit(node, row, column, input.checked));
      return input;
    }
    case "date": {
      const input = document.createElement("input");
      input.type = "date";
      input.className = "dbembed-input";
      input.value = typeof cell.raw === "string" ? cell.raw : "";
      input.addEventListener("change", () => commit(node, row, column, input.value));
      return input;
    }
    case "number": {
      const input = document.createElement("input");
      input.type = "text";
      input.className = "dbembed-input dbembed-number";
      input.value = cell.raw === null || cell.raw === undefined ? "" : String(cell.raw);
      const send = () => {
        const parsed = parseFloat(input.value.replace(/,/g, ""));
        commit(node, row, column, Number.isNaN(parsed) ? "" : parsed);
      };
      input.addEventListener("change", send);
      input.addEventListener("keydown", (event) => {
        if (event.key === "Enter") input.blur();
      });
      return input;
    }
    case "select":
    case "multiSelect":
      return optionChips(node, column, row, cell, column.kind === "multiSelect");
    case "relation":
      return relationChips(node, column, row, cell);
    case "rollup": {
      const span = document.createElement("span");
      span.className = "dbembed-readonly";
      span.textContent = "—";
      return span;
    }
    default: {
      // text / url / person: a plain input holding the raw string.
      const input = document.createElement("input");
      input.type = "text";
      input.className = "dbembed-input";
      input.value = typeof cell.raw === "string" ? cell.raw : (cell.display || "");
      input.addEventListener("change", () => commit(node, row, column, input.value));
      input.addEventListener("keydown", (event) => {
        if (event.key === "Enter") input.blur();
      });
      return input;
    }
  }
}

// Select/multi-select: chips + a popup of the snapshot's options.
function optionChips(node, column, row, cell, multiple) {
  const wrap = document.createElement("div");
  wrap.className = "dbembed-chips";
  const selected = Array.isArray(cell.raw) ? cell.raw : [];
  const options = column.options || [];

  const selectedOptions = selected
    .map((id) => options.find((option) => option.id === id))
    .filter(Boolean);
  if (selectedOptions.length === 0) {
    const hint = document.createElement("span");
    hint.className = "dbembed-empty-hint";
    hint.textContent = "—";
    wrap.appendChild(hint);
  }
  for (const option of selectedOptions) {
    const chip = document.createElement("span");
    chip.className = "dbembed-chip";
    chip.textContent = option.name;
    chip.style.background = `color-mix(in srgb, ${option.color} 22%, transparent)`;
    wrap.appendChild(chip);
  }

  wrap.addEventListener("click", () => {
    openPickPopup(wrap, options.map((option) => ({
      id: option.id,
      label: option.name,
      color: option.color,
      selected: selected.includes(option.id),
    })), multiple, (ids) => commit(node, row, column, ids));
  });
  return wrap;
}

// Relation: chips + a popup of the target database's rows.
function relationChips(node, column, row, cell) {
  const wrap = document.createElement("div");
  wrap.className = "dbembed-chips";
  const selected = Array.isArray(cell.raw) ? cell.raw : [];
  const targets = column.targets || [];

  const label = selected
    .map((id) => (targets.find((target) => target.id === id) || {}).title)
    .filter(Boolean)
    .join(", ");
  const span = document.createElement("span");
  span.className = label ? "dbembed-relation" : "dbembed-empty-hint";
  span.textContent = label || "—";
  wrap.appendChild(span);

  wrap.addEventListener("click", () => {
    openPickPopup(wrap, targets.map((target) => ({
      id: target.id,
      label: target.title,
      color: null,
      selected: selected.includes(target.id),
    })), true, (ids) => commit(node, row, column, ids));
  });
  return wrap;
}

// A small toggle-list popup (slash-menu pattern; used for selects/relations).
let activePickPopup = null;

function closePickPopup() {
  if (!activePickPopup) return;
  document.removeEventListener("mousedown", activePickPopup.dismiss, true);
  activePickPopup.element.remove();
  activePickPopup = null;
}

function openPickPopup(anchor, items, multiple, onCommit) {
  closePickPopup();
  const popup = document.createElement("div");
  popup.className = "dbembed-popup";

  const state = new Set(items.filter((item) => item.selected).map((item) => item.id));

  const rerender = () => {
    popup.innerHTML = "";
    if (items.length === 0) {
      const empty = document.createElement("div");
      empty.className = "dbembed-more";
      empty.textContent = "No options.";
      popup.appendChild(empty);
    }
    for (const item of items) {
      const rowEl = document.createElement("div");
      rowEl.className = "dbembed-popup-row";
      const label = document.createElement("span");
      label.className = "dbembed-chip";
      if (item.color) {
        label.style.background = `color-mix(in srgb, ${item.color} 22%, transparent)`;
      }
      label.textContent = item.label;
      rowEl.appendChild(label);
      if (state.has(item.id)) {
        const mark = document.createElement("span");
        mark.className = "dbembed-popup-mark";
        mark.textContent = "✓";
        rowEl.appendChild(mark);
      }
      rowEl.addEventListener("mousedown", (event) => {
        event.preventDefault();
        if (multiple) {
          state.has(item.id) ? state.delete(item.id) : state.add(item.id);
          onCommit(Array.from(state));
          rerender();
        } else {
          const next = state.has(item.id) ? [] : [item.id];
          onCommit(next);
          closePickPopup();
        }
      });
      popup.appendChild(rowEl);
    }
  };
  rerender();

  document.body.appendChild(popup);
  const rect = anchor.getBoundingClientRect();
  const below = rect.bottom + 4;
  const top = below + popup.offsetHeight > window.innerHeight
    ? Math.max(6, rect.top - popup.offsetHeight - 4)
    : below;
  popup.style.top = `${top}px`;
  popup.style.left = `${Math.max(6, Math.min(rect.left, window.innerWidth - popup.offsetWidth - 6))}px`;

  const dismiss = (event) => {
    if (!popup.contains(event.target)) closePickPopup();
  };
  setTimeout(() => document.addEventListener("mousedown", dismiss, true), 0);
  activePickPopup = { element: popup, dismiss };
}
