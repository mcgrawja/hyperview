//
// Notion-style "/" command menu for the Hyperview editor.
//
// Built on @tiptap/suggestion: typing "/" opens a floating, keyboard-navigable
// menu of block commands; typing filters it; Enter/click applies the command
// to the current block. Dependency-free popup (no tippy) so the bundle stays
// self-contained.
//

import { Extension } from "@tiptap/core";
import Suggestion from "@tiptap/suggestion";

function post(msg) {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hyperview) {
    window.webkit.messageHandlers.hyperview.postMessage(msg);
  }
}

const ITEMS = [
  { title: "Text", hint: "Plain paragraph", keywords: "paragraph plain",
    run: (e, r) => e.chain().focus().deleteRange(r).setParagraph().run() },
  { title: "Heading 1", hint: "Large section heading", keywords: "h1 title",
    run: (e, r) => e.chain().focus().deleteRange(r).setHeading({ level: 1 }).run() },
  { title: "Heading 2", hint: "Medium section heading", keywords: "h2 subtitle",
    run: (e, r) => e.chain().focus().deleteRange(r).setHeading({ level: 2 }).run() },
  { title: "Heading 3", hint: "Small section heading", keywords: "h3",
    run: (e, r) => e.chain().focus().deleteRange(r).setHeading({ level: 3 }).run() },
  { title: "Bulleted list", hint: "Simple bullet points", keywords: "ul bullet list -",
    run: (e, r) => e.chain().focus().deleteRange(r).toggleBulletList().run() },
  { title: "Numbered list", hint: "Ordered list", keywords: "ol number 1.",
    run: (e, r) => e.chain().focus().deleteRange(r).toggleOrderedList().run() },
  { title: "To-do list", hint: "Checklist with checkboxes", keywords: "todo task check []",
    run: (e, r) => e.chain().focus().deleteRange(r).toggleTaskList().run() },
  { title: "Quote", hint: "Block quotation", keywords: "blockquote >",
    run: (e, r) => e.chain().focus().deleteRange(r).toggleBlockquote().run() },
  { title: "Code block", hint: "Monospaced code", keywords: "code ```",
    run: (e, r) => e.chain().focus().deleteRange(r).toggleCodeBlock().run() },
  { title: "Toggle", hint: "Collapsible block", keywords: "toggle collapse details fold >",
    run: (e, r) => { e.chain().focus().deleteRange(r).run(); e.commands.setToggle(); } },
  { title: "Callout", hint: "Emphasized note with an emoji", keywords: "callout info aside emphasis",
    run: (e, r) => e.chain().focus().deleteRange(r).setCallout().run() },
  { title: "Image", hint: "Insert a picture", keywords: "image picture photo img",
    run: (e, r) => { e.chain().focus().deleteRange(r).run(); post({ type: "requestImage" }); } },
  { title: "2 Columns", hint: "Side-by-side layout", keywords: "columns two layout side",
    run: (e, r) => { e.chain().focus().deleteRange(r).run(); e.commands.setColumns(2); } },
  { title: "3 Columns", hint: "Three-column layout", keywords: "columns three layout side",
    run: (e, r) => { e.chain().focus().deleteRange(r).run(); e.commands.setColumns(3); } },
  { title: "Divider", hint: "Horizontal rule", keywords: "hr rule line ---",
    run: (e, r) => e.chain().focus().deleteRange(r).setHorizontalRule().run() },
  { title: "Table", hint: "3×3 table with header row", keywords: "table grid cells",
    run: (e, r) => e.chain().focus().deleteRange(r).insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run() },
  { title: "Sub-page", hint: "Create a page inside this page", keywords: "subpage child page new nested",
    run: (e, r) => { e.chain().focus().deleteRange(r).run(); post({ type: "createSubpage" }); } },
  { title: "Linked database", hint: "Embed a database view", keywords: "database table view embed linked db",
    run: (e, r) => { e.chain().focus().deleteRange(r).run(); post({ type: "requestDBEmbedPicker" }); } },
  { title: "Link to note", hint: "Link to another Hyperview note", keywords: "link note wiki [[",
    run: (e, r) => { e.chain().focus().deleteRange(r).run(); post({ type: "requestNoteLink" }); } },
  { title: "Link to file", hint: "Link to a file on this Mac", keywords: "link file attach finder",
    run: (e, r) => { e.chain().focus().deleteRange(r).run(); post({ type: "requestFileLink" }); } },
  // Table editing — these only apply with the cursor inside a table; type
  // "/table" in a cell to filter down to them.
  { title: "Table: add row", hint: "Insert a row below", keywords: "table row insert below",
    run: (e, r) => e.chain().focus().deleteRange(r).addRowAfter().run() },
  { title: "Table: add column", hint: "Insert a column to the right", keywords: "table column insert right",
    run: (e, r) => e.chain().focus().deleteRange(r).addColumnAfter().run() },
  { title: "Table: delete row", hint: "Remove the current row", keywords: "table row delete remove",
    run: (e, r) => e.chain().focus().deleteRange(r).deleteRow().run() },
  { title: "Table: delete column", hint: "Remove the current column", keywords: "table column delete remove",
    run: (e, r) => e.chain().focus().deleteRange(r).deleteColumn().run() },
  { title: "Table: delete table", hint: "Remove the whole table", keywords: "table delete remove",
    run: (e, r) => e.chain().focus().deleteRange(r).deleteTable().run() },
];

// Shared by the "/" command menu and the "@" page-mention menu (page-mention.js).
export class CommandMenu {
  constructor() {
    this.element = document.createElement("div");
    this.element.className = "slash-menu";
    document.body.appendChild(this.element);
    this.items = [];
    this.selected = 0;
    this.command = null;
    this.hide();
  }

  update(props) {
    this.items = props.items;
    this.command = props.command;
    if (!this.items.length) { this.hide(); return; }
    if (this.selected >= this.items.length) this.selected = 0;
    this.renderItems();
    const rect = props.clientRect && props.clientRect();
    if (rect) {
      this.element.style.display = "block";
      const menuHeight = this.element.offsetHeight;
      const below = rect.bottom + 6;
      const top = below + menuHeight > window.innerHeight
        ? Math.max(6, rect.top - menuHeight - 6)
        : below;
      this.element.style.top = `${top}px`;
      this.element.style.left = `${Math.min(rect.left, window.innerWidth - 240)}px`;
    }
  }

  renderItems() {
    this.element.innerHTML = "";
    this.items.forEach((item, index) => {
      const row = document.createElement("div");
      row.className = "slash-item" + (index === this.selected ? " selected" : "");
      const title = document.createElement("div");
      title.className = "slash-title";
      title.textContent = item.title;
      const hint = document.createElement("div");
      hint.className = "slash-hint";
      hint.textContent = item.hint;
      row.appendChild(title);
      row.appendChild(hint);
      row.addEventListener("mousedown", (event) => {
        event.preventDefault();
        this.command(item);
      });
      row.addEventListener("mouseenter", () => {
        this.selected = index;
        this.renderItems();
      });
      this.element.appendChild(row);
    });
  }

  onKeyDown(event) {
    if (event.key === "ArrowDown") {
      this.selected = (this.selected + 1) % this.items.length;
      this.renderItems();
      this.scrollSelectedIntoView();
      return true;
    }
    if (event.key === "ArrowUp") {
      this.selected = (this.selected - 1 + this.items.length) % this.items.length;
      this.renderItems();
      this.scrollSelectedIntoView();
      return true;
    }
    if (event.key === "Enter") {
      const item = this.items[this.selected];
      if (item) this.command(item);
      return true;
    }
    if (event.key === "Escape") {
      this.hide();
      return true;
    }
    return false;
  }

  scrollSelectedIntoView() {
    const row = this.element.children[this.selected];
    if (row) row.scrollIntoView({ block: "nearest" });
  }

  hide() {
    this.element.style.display = "none";
  }

  destroy() {
    this.hide();
  }
}

export const SlashCommands = Extension.create({
  name: "slashCommands",

  addProseMirrorPlugins() {
    let menu = null;
    return [
      Suggestion({
        editor: this.editor,
        char: "/",
        allowSpaces: false,
        items: ({ query }) => {
          const q = query.toLowerCase();
          return ITEMS.filter(
            (item) =>
              item.title.toLowerCase().includes(q) || item.keywords.includes(q)
          ).slice(0, 13);
        },
        command: ({ editor, range, props }) => props.run(editor, range),
        render: () => ({
          onStart: (props) => {
            menu = new CommandMenu();
            menu.selected = 0;
            menu.update(props);
          },
          onUpdate: (props) => menu && menu.update(props),
          onKeyDown: (props) => (menu ? menu.onKeyDown(props.event) : false),
          onExit: () => {
            if (menu) { menu.destroy(); menu = null; }
          },
        }),
      }),
    ];
  },
});
