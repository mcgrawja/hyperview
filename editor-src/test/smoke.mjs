//
// Editor bundle smoke test (node + jsdom): loads the BUILT editor.js exactly
// as the WKWebView would and fails loudly if the editor doesn't construct.
//
// Exists because a duplicate Suggestion PluginKey once made `new Editor()`
// throw — a completely dead editor that type-checks, bundles, and greps fine.
// Run after every `npm run build`: `npm run test:smoke`.
//

import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const bundlePath = join(here, "../../Unifyr/Unifyr/Editor/editor.js");

const dom = new JSDOM(`<!DOCTYPE html><html><body><div id="editor"></div></body></html>`, {
  url: "http://localhost/",
  pretendToBeVisual: true, // requestAnimationFrame etc.
});

// The bundle is an IIFE written for a browser; give it browser globals.
const { window } = dom;
for (const key of ["window", "document", "navigator", "MutationObserver", "Node", "Element", "HTMLElement", "Document", "DocumentFragment", "Text", "getComputedStyle", "requestAnimationFrame", "cancelAnimationFrame", "FileReader", "CustomEvent", "MouseEvent", "KeyboardEvent", "InputEvent", "DOMParser", "XMLSerializer", "Range", "NodeFilter"]) {
  if (window[key] === undefined) continue;
  try {
    Object.defineProperty(globalThis, key, { value: window[key], configurable: true, writable: true });
  } catch {
    // Some globals (navigator on newer Node) are getter-only — skip; the
    // jsdom window's own copy is what the bundle sees via `window.` anyway.
  }
}

const failures = [];
function check(label, condition) {
  console.log(`${condition ? "ok  " : "FAIL"} ${label}`);
  if (!condition) failures.push(label);
}

// Any postMessage traffic the bundle emits (it no-ops without webkit, but an
// editorError posted via console tells us the construction failed).
const consoleErrors = [];
const originalError = console.error;
console.error = (...parts) => {
  consoleErrors.push(parts.map(String).join(" "));
  originalError(...parts);
};

// Execute the bundle.
new Function(readFileSync(bundlePath, "utf8"))();

check("editor constructed without console errors", consoleErrors.length === 0);
check("window.hyperview exists", !!window.hyperview);
check("ProseMirror mounted", !!window.document.querySelector(".ProseMirror"));

// Load a document touching every custom node — a schema regression in any of
// them throws here.
const doc = {
  type: "doc",
  content: [
    { type: "heading", attrs: { level: 1 }, content: [{ type: "text", text: "Smoke" }] },
    { type: "callout", attrs: { emoji: "⚠️" }, content: [{ type: "paragraph", content: [{ type: "text", text: "callout" }] }] },
    { type: "toggle", attrs: { open: true }, content: [
      { type: "toggleSummary", content: [{ type: "text", text: "Summary" }] },
      { type: "toggleBody", content: [{ type: "paragraph", content: [{ type: "text", text: "body" }] }] },
    ]},
    { type: "codeBlock", attrs: { language: "swift" }, content: [{ type: "text", text: "let x = 1" }] },
    { type: "columnList", attrs: { widths: "30.0,70.0" }, content: [
      { type: "column", content: [{ type: "paragraph", content: [{ type: "text", text: "left" }] }] },
      { type: "column", content: [{ type: "paragraph", content: [{ type: "text", text: "right" }] }] },
    ]},
    { type: "paragraph", content: [
      { type: "text", text: "see " },
      { type: "pageMention", attrs: { noteID: "A", title: "Other" } },
    ]},
    { type: "subpage", attrs: { noteID: "B", title: "Child" } },
    { type: "dbembed", attrs: { noteID: "C", title: "Tracker" } },
    { type: "image", attrs: { src: "unifyr-asset://X", width: 320 } },
    { type: "bookmark", attrs: { url: "https://example.com", title: "Example" } },
    { type: "agenda", attrs: { scope: "today" } },
    { type: "pageembed", attrs: { noteID: "D", title: "Mirror" } },
  ],
};

let loadError = null;
try {
  window.hyperview.loadDocument(JSON.stringify(doc));
} catch (error) {
  loadError = error;
}
check("loadDocument with every custom node", !loadError);
if (loadError) console.error(loadError);

check("callout rendered", !!window.document.querySelector(".callout"));
check("toggle rendered", !!window.document.querySelector(".toggle"));
check("columns rendered", !!window.document.querySelector(".column-list"));
check("mention rendered", !!window.document.querySelector(".page-mention"));
check("subpage rendered", !!window.document.querySelector(".subpage-block"));
check("dbembed rendered", !!window.document.querySelector(".dbembed"));
check("bookmark rendered", !!window.document.querySelector(".bookmark-block"));
check("agenda rendered", !!window.document.querySelector(".agenda-block"));
check("pageembed rendered", !!window.document.querySelector(".pageembed"));

if (failures.length) {
  console.error(`\n${failures.length} smoke check(s) FAILED`);
  process.exit(1);
}
console.log("\neditor bundle smoke: all checks passed");
// Explicit exit: nodeViews may leave timers (setTimeout width-apply, jsdom
// rAF) in the loop — a smoke script should end when its checks end.
process.exit(0);
