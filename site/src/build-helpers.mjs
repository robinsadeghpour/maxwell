// k("⇧ ⌘ ⌫") → one keycap per space-separated token, kept on one line.
export const k = (s) => `<span class="kc">${s.split(" ").map((t) => `<kbd>${t}</kbd>`).join("")}</span>`;
