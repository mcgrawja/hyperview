//
//  Unifyr note editor — TipTap build (D6).
//
//  Bundled by esbuild into a single self-contained Unifyr/Editor/editor.js
//  (no network dependency). Speaks the §5 bridge and ProseMirror doc JSON
//  shape that Swift's BlockSerializer round-trips:
//
//    Swift → JS : window.hyperview.loadDocument(json) / insertLink / insertImage
//    JS → Swift : postMessage({type:"ready"})
//                 postMessage({type:"documentChanged", doc})   (debounced 500ms)
//                 postMessage({type:"saveImage"|"requestImage"|"requestNoteLink"
//                              |"requestFileLink"|"openLink"})
//
//  ("hyperview" is the bridge wire name — it deliberately did not rename.)
//

import { Editor } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import TaskList from "@tiptap/extension-task-list";
import TaskItem from "@tiptap/extension-task-item";
import Placeholder from "@tiptap/extension-placeholder";
import Link from "@tiptap/extension-link";
import Table from "@tiptap/extension-table";
import TableRow from "@tiptap/extension-table-row";
import TableHeader from "@tiptap/extension-table-header";
import TableCell from "@tiptap/extension-table-cell";
import { ResizableImage } from "./image-block.js";
import { SlashCommands } from "./slash-menu.js";
import { Callout } from "./callout.js";
import { Toggle, ToggleSummary, ToggleBody } from "./toggle.js";
import { CodeBlock } from "./code-block.js";
import { DragHandle } from "./drag-handle.js";
import { PageMention, PageMentionSuggestion, pageIndex } from "./page-mention.js";
import { Subpage } from "./subpage.js";
import { DBEmbed, deliverDBEmbed, refreshDBEmbeds } from "./dbembed.js";
import { ColumnList, Column } from "./columns.js";
import { Bookmark, deliverBookmark } from "./bookmark.js";
import { Agenda, deliverAgenda } from "./agenda.js";

function post(msg) {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hyperview) {
    window.webkit.messageHandlers.hyperview.postMessage(msg);
  }
}

const EMPTY_DOC = { type: "doc", content: [{ type: "paragraph" }] };

let saveTimer = null;
function scheduleChange(editor) {
  if (saveTimer) clearTimeout(saveTimer);
  saveTimer = setTimeout(function () {
    post({ type: "documentChanged", doc: editor.getJSON() });
  }, 500);
}

// Pasted/dropped images go to Swift as data URLs; Swift stores an Asset and
// calls back insertImage with a unifyr-asset:// URL, so note documents stay
// small (CloudKit records must — the bytes live in the Asset's external
// storage, not the block JSON).
function sendImageFile(file) {
  const reader = new FileReader();
  reader.onload = function () {
    post({ type: "saveImage", dataURL: reader.result, filename: file.name || "image.png" });
  };
  reader.readAsDataURL(file);
}

function firstImageFile(list) {
  for (const item of list || []) {
    const file = item.getAsFile ? (item.type && item.type.startsWith("image/") ? item.getAsFile() : null) : item;
    if (file && file.type && file.type.startsWith("image/")) return file;
  }
  return null;
}

// If editor construction throws (a bad node spec, a duplicate plugin key —
// it has happened), surface it loudly instead of leaving a dead, silent
// editor: the error goes to the console AND to Swift as "editorError".
let editor = null;
function buildEditor() {
  return new Editor({
  element: document.getElementById("editor"),
  extensions: [
    // Heading capped at 1–3 to match Unifyr's block kinds (§4.2). The stock
    // code block yields to the lowlight-highlighted one below.
    StarterKit.configure({ heading: { levels: [1, 2, 3] }, codeBlock: false }),
    CodeBlock,
    TaskList,
    TaskItem.configure({ nested: true }),
    // Clicks are intercepted below and routed to Swift (note links, file
    // links, web links) — the editor itself never navigates.
    Link.configure({ openOnClick: false, autolink: true, linkOnPaste: true }),
    // Cells hold block content, so task lists nest inside table cells.
    Table.configure({ resizable: false }),
    TableRow,
    TableHeader,
    TableCell,
    ResizableImage,
    Callout,
    Toggle,
    ToggleSummary,
    ToggleBody,
    DragHandle,
    PageMention,
    PageMentionSuggestion,
    Subpage,
    DBEmbed,
    ColumnList,
    Column,
    Bookmark,
    Agenda,
    Placeholder.configure({ placeholder: "Type ‘/’ for commands…" }),
    SlashCommands,
  ],
  content: EMPTY_DOC,
  autofocus: false,
  editorProps: {
    handlePaste(_view, event) {
      const file = firstImageFile(event.clipboardData && event.clipboardData.items);
      if (!file) return false;
      event.preventDefault();
      sendImageFile(file);
      return true;
    },
    handleDrop(_view, event, _slice, moved) {
      if (moved) return false; // an internal block drag, not a file drop
      const file = firstImageFile(event.dataTransfer && event.dataTransfer.files);
      if (!file) return false;
      event.preventDefault();
      sendImageFile(file);
      return true;
    },
  },
  onUpdate: function ({ editor }) {
    scheduleChange(editor);
  },
  });
}

try {
  editor = buildEditor();
} catch (error) {
  console.error("Unifyr editor failed to initialize:", error);
  post({ type: "editorError", message: String((error && error.message) || error) });
}

// Any link click (note link, file link, web link) goes to Swift, which knows
// how to route each scheme. preventDefault keeps the WKWebView in place.
document.getElementById("editor").addEventListener("click", function (event) {
  const anchor = event.target.closest("a[href]");
  if (!anchor) return;
  event.preventDefault();
  post({ type: "openLink", href: anchor.getAttribute("href") });
});

window.hyperview = {
  loadDocument: function (docOrJson) {
    if (!editor) return;
    const doc = typeof docOrJson === "string" ? JSON.parse(docOrJson) : docOrJson;
    const content = doc && Array.isArray(doc.content) && doc.content.length ? doc : EMPTY_DOC;
    // emitUpdate=false so loading a note does not echo back a documentChanged.
    editor.commands.setContent(content, false);
  },
  applyExternalChange: function (_patch) {
    // TODO (§5): apply a block-level patch when CloudKit updates an open note.
    // For now Swift re-issues loadDocument on external change.
  },
  // Swift → JS: insert a link at the cursor (note picker / file picker
  // results). The trailing plain space stops the mark from bleeding into
  // whatever the user types next.
  insertLink: function (href, text) {
    if (!editor) return;
    const label = text && text.length ? text : href;
    editor
      .chain()
      .focus()
      .insertContent([
        { type: "text", text: label, marks: [{ type: "link", attrs: { href: href } }] },
        { type: "text", text: " " },
      ])
      .run();
  },
  // Swift → JS: the stored-asset URL for a saved image (saveImage /
  // requestImage results).
  insertImage: function (src, alt) {
    if (!editor) return;
    editor
      .chain()
      .focus()
      .insertContent({ type: "image", attrs: { src: src, alt: alt || null } })
      .run();
  },
  // Swift → JS: the page list the "@" mention menu searches. Pushed on load
  // and on document switch so it tracks renames/creates.
  setPages: function (pagesOrJson) {
    const pages = typeof pagesOrJson === "string" ? JSON.parse(pagesOrJson) : pagesOrJson;
    pageIndex.pages = Array.isArray(pages) ? pages : [];
  },
  // Swift → JS: a child page was created for "/Sub-page" — embed it here.
  insertSubpage: function (id, title, emoji) {
    if (!editor) return;
    editor
      .chain()
      .focus()
      .insertContent({ type: "subpage", attrs: { noteID: id, title: title || "Untitled", emoji: emoji || null } })
      .run();
  },
  // Swift → JS: the database view picked for "/Linked database".
  insertDBEmbed: function (id, viewID, title, emoji) {
    if (!editor) return;
    editor
      .chain()
      .focus()
      .insertContent({
        type: "dbembed",
        attrs: { noteID: id, viewID: viewID || null, title: title || "Untitled", emoji: emoji || null },
      })
      .run();
  },
  // Swift → JS: a dbembed snapshot answering requestDBEmbed.
  deliverDBEmbed: deliverDBEmbed,
  // Swift → JS: after an embed write, every embed of that database refetches.
  refreshDBEmbeds: refreshDBEmbeds,
  // Swift → JS: a fetched page <title> answering resolveBookmark.
  deliverBookmark: deliverBookmark,
  // Swift → JS: contacts/events/reminders for the "@" mention menu.
  setMentionSources: function (sourcesOrJson) {
    const sources = typeof sourcesOrJson === "string" ? JSON.parse(sourcesOrJson) : sourcesOrJson;
    pageIndex.sources = Array.isArray(sources) ? sources : [];
  },
  // Swift → JS: an agenda snapshot answering requestAgenda.
  deliverAgenda: deliverAgenda,
  // Swift → JS: centered column (default) vs full-width (PageProps.wideLayout).
  setWide: function (wide) {
    document.body.classList.toggle("wide", !!wide);
  },
};

if (editor) {
  post({ type: "ready" });
}
