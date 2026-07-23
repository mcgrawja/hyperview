//
// "/ask" — Claude in the editor (integration round 3). A prompt popup posts
// askClaude to Swift; Swift runs a one-shot completion with the page as
// context, appends the answer to the note, and reloads the document. A
// fixed toast shows progress; window.hyperview.askDone clears it (and shows
// the error, if any).
//

function post(msg) {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hyperview) {
    window.webkit.messageHandlers.hyperview.postMessage(msg);
  }
}

let toast = null;

function showToast(text, isError) {
  hideToast();
  toast = document.createElement("div");
  toast.className = "ask-toast" + (isError ? " error" : "");
  toast.textContent = text;
  document.body.appendChild(toast);
  if (isError) setTimeout(hideToast, 6000);
}

export function hideToast() {
  if (toast) { toast.remove(); toast = null; }
}

export function askDone(errorMessage) {
  if (errorMessage) {
    showToast(errorMessage, true);
  } else {
    hideToast();
  }
}

export function promptAsk() {
  const overlay = document.createElement("div");
  overlay.className = "bookmark-prompt";

  const box = document.createElement("div");
  box.className = "bookmark-prompt-box";
  const label = document.createElement("div");
  label.className = "bookmark-prompt-label";
  label.textContent = "Ask Claude about this page";
  const input = document.createElement("input");
  input.className = "emoji-input";
  input.placeholder = "Summarize · continue writing · extract action items…";

  const finish = (commit) => {
    overlay.remove();
    const value = input.value.trim();
    if (!commit || !value) return;
    showToast("🤖 Asking Claude…", false);
    post({ type: "askClaude", prompt: value });
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
