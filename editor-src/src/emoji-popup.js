//
// Tiny emoji picker popup for the editor (callout badges). Mirrors the Swift
// EmojiIconPicker: a curated grid plus a free-form field that takes anything.
// Dependency-free DOM, same pattern as the slash menu.
//

const COMMON = [
  "💡", "⚠️", "📌", "✅", "❓", "🔥", "💭", "🚧",
  "📝", "📚", "🎯", "🚀", "⭐️", "🧠", "🛠️", "❤️",
  "🏠", "💰", "📈", "🗓️", "⏰", "🍽️", "✈️", "🚗",
  "🖨️", "🎵", "🎬", "🌱", "🎁", "🔒", "👀", "🎉",
];

let activePopup = null;

export function showEmojiPicker(anchorRect, onPick) {
  closeEmojiPicker();

  const popup = document.createElement("div");
  popup.className = "emoji-popup";

  const grid = document.createElement("div");
  grid.className = "emoji-grid";
  for (const emoji of COMMON) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "emoji-cell";
    button.textContent = emoji;
    button.addEventListener("mousedown", (event) => {
      event.preventDefault();
      onPick(emoji);
      closeEmojiPicker();
    });
    grid.appendChild(button);
  }
  popup.appendChild(grid);

  const input = document.createElement("input");
  input.className = "emoji-input";
  input.placeholder = "Any emoji…";
  input.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      closeEmojiPicker();
      return;
    }
    if (event.key !== "Enter") return;
    event.preventDefault();
    const value = input.value.trim();
    if (!value) return;
    // First grapheme-ish: good enough for emoji input.
    onPick(Array.from(value)[0]);
    closeEmojiPicker();
  });
  popup.appendChild(input);

  document.body.appendChild(popup);
  const below = anchorRect.bottom + 6;
  const top = below + popup.offsetHeight > window.innerHeight
    ? Math.max(6, anchorRect.top - popup.offsetHeight - 6)
    : below;
  popup.style.top = `${top}px`;
  popup.style.left = `${Math.max(6, Math.min(anchorRect.left, window.innerWidth - popup.offsetWidth - 6))}px`;

  const dismiss = (event) => {
    if (!popup.contains(event.target)) closeEmojiPicker();
  };
  // Deferred so the opening click doesn't immediately dismiss.
  setTimeout(() => document.addEventListener("mousedown", dismiss, true), 0);

  activePopup = { element: popup, dismiss };
  input.focus();
}

export function closeEmojiPicker() {
  if (!activePopup) return;
  document.removeEventListener("mousedown", activePopup.dismiss, true);
  activePopup.element.remove();
  activePopup = null;
}
