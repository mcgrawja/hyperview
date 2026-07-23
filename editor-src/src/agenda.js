//
// "/agenda" block (integration round 2): a live slice of today's calendar
// events and the week's due reminders, fetched from Swift on every mount
// (requestAgenda → deliverAgenda). Items click through to their module via
// openMention. The block stores only {scope}; the data never persists.
//

import { Node } from "@tiptap/core";

function post(msg) {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hyperview) {
    window.webkit.messageHandlers.hyperview.postMessage(msg);
  }
}

export const agendaRequests = { pending: {}, counter: 0 };

export function deliverAgenda(ref, json) {
  const render = agendaRequests.pending[ref];
  if (!render) return;
  delete agendaRequests.pending[ref];
  render(json ? JSON.parse(json) : null);
}

export const Agenda = Node.create({
  name: "agenda",
  group: "block",
  atom: true,
  selectable: true,

  addAttributes() {
    return { scope: { default: "today" } };
  },

  parseHTML() {
    return [{ tag: "div.agenda-block" }];
  },

  renderHTML({ HTMLAttributes }) {
    return ["div", { ...HTMLAttributes, class: "agenda-block" }, "Agenda"];
  },

  addNodeView() {
    return ({ node }) => {
      const dom = document.createElement("div");
      dom.className = "agenda-block";
      dom.textContent = "Loading agenda…";

      const ref = `agenda-${++agendaRequests.counter}`;
      agendaRequests.pending[ref] = (snapshot) => render(dom, snapshot);
      post({ type: "requestAgenda", scope: node.attrs.scope || "today", ref: ref });

      return {
        dom,
        stopEvent(event) {
          return dom.contains(event.target) && event.type === "click";
        },
        ignoreMutation() {
          return true;
        },
      };
    };
  },

  addCommands() {
    return {
      insertAgenda:
        () =>
        ({ chain }) =>
          chain().insertContent({ type: this.name, attrs: { scope: "today" } }).run(),
    };
  },
});

function render(dom, snapshot) {
  dom.innerHTML = "";
  if (!snapshot) {
    dom.textContent = "Agenda unavailable (calendar access?).";
    return;
  }

  const header = document.createElement("div");
  header.className = "agenda-header";
  header.textContent = `📆 ${snapshot.date || "Today"}`;
  dom.appendChild(header);

  const addRow = (icon, label, meta, onClick) => {
    const row = document.createElement("div");
    row.className = "agenda-row";
    const iconEl = document.createElement("span");
    iconEl.textContent = icon;
    const labelEl = document.createElement("span");
    labelEl.className = "agenda-label";
    labelEl.textContent = label;
    const metaEl = document.createElement("span");
    metaEl.className = "agenda-meta";
    metaEl.textContent = meta;
    row.appendChild(iconEl);
    row.appendChild(labelEl);
    row.appendChild(metaEl);
    row.addEventListener("click", onClick);
    dom.appendChild(row);
  };

  for (const event of snapshot.events || []) {
    addRow("🗓️", event.title, event.time, () =>
      post({ type: "openMention", kind: "event", id: event.id, dateISO: event.dateISO })
    );
  }
  for (const reminder of snapshot.reminders || []) {
    addRow("✅", reminder.title, reminder.due, () =>
      post({ type: "openMention", kind: "reminder", id: reminder.id })
    );
  }
  if ((snapshot.events || []).length === 0 && (snapshot.reminders || []).length === 0) {
    const empty = document.createElement("div");
    empty.className = "agenda-meta";
    empty.textContent = "Nothing scheduled — clear day.";
    dom.appendChild(empty);
  }
}
