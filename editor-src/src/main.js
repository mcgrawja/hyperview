//
//  Hyperview note editor — TipTap build (D6).
//
//  Bundled by esbuild into a single self-contained Hyperview/Editor/editor.js
//  (no network dependency). Speaks the SAME §5 bridge and ProseMirror doc JSON
//  shape as the interim editor and Swift's BlockSerializer, so it is a drop-in
//  replacement:
//
//    Swift → JS : window.hyperview.loadDocument(json) / applyExternalChange(patch)
//    JS → Swift : postMessage({type:"ready"})
//                 postMessage({type:"documentChanged", doc})   (debounced 500ms)
//

import { Editor } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import TaskList from "@tiptap/extension-task-list";
import TaskItem from "@tiptap/extension-task-item";
import Placeholder from "@tiptap/extension-placeholder";

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

const editor = new Editor({
  element: document.getElementById("editor"),
  extensions: [
    // Heading capped at 1–3 to match Hyperview's block kinds (§4.2).
    StarterKit.configure({ heading: { levels: [1, 2, 3] } }),
    TaskList,
    TaskItem.configure({ nested: true }),
    Placeholder.configure({ placeholder: "Type ‘/’ for commands…" }),
  ],
  content: EMPTY_DOC,
  autofocus: false,
  onUpdate: function ({ editor }) {
    scheduleChange(editor);
  },
});

window.hyperview = {
  loadDocument: function (docOrJson) {
    const doc = typeof docOrJson === "string" ? JSON.parse(docOrJson) : docOrJson;
    const content = doc && Array.isArray(doc.content) && doc.content.length ? doc : EMPTY_DOC;
    // emitUpdate=false so loading a note does not echo back a documentChanged.
    editor.commands.setContent(content, false);
  },
  applyExternalChange: function (_patch) {
    // TODO (§5): apply a block-level patch when CloudKit updates an open note.
    // For now Swift re-issues loadDocument on external change.
  },
};

post({ type: "ready" });
