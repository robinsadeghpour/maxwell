// Product vignettes, drawn in HTML so they stay sharp, match the site, and show no real data.
// Every name, branch and message here is invented.

const C = { need: "var(--need)", turn: "var(--turn)", work: "var(--work)", safe: "var(--safe)", limit: "var(--limit)" };
const dot = (c, open) => `<i class="d${open ? " o" : ""}" style="--c:${C[c]}"></i>`;
const plate = (inner, caption) =>
  `<figure class="fig"><div class="plate" aria-hidden="true">${inner}</div>${caption ? `<figcaption>${caption}</figcaption>` : ""}</figure>`;
const chrome = (title, right = "") =>
  `<div class="wh"><span class="tl"><i></i><i></i><i></i></span><b>${title}</b><span class="sp"></span>${right}</div>`;

export const groups = (caption) => plate(`<div class="w sm">
  ${chrome("Acme", "⌘1")}
  <div class="gh" style="--c:${C.need}">${dot("need")} Needs you <span>1</span></div>
  <div class="row sel" style="--c:${C.need}">${dot("need")}<b>Billing totals <em>2m</em></b><small>Allow Bash: npm run migrate?</small></div>
  <div class="gh" style="--c:${C.turn}">${dot("turn")} Your turn <span>2</span></div>
  <div class="row">${dot("turn")}<b>Invoice PDF export <em>6m</em></b><small>PR #212 is open. Want me to watch CI?</small></div>
  <div class="row">${dot("turn")}<b>Onboarding copy <em>14m</em></b><small>Three options in copy.md</small></div>
  <div class="gh" style="--c:${C.work}">${dot("work")} Working <span>2</span></div>
  <div class="row">${dot("work")}<b>Search index rebuild <em>now</em></b><small>Running tests · 41 of 120</small></div>
  <div class="row">${dot("work")}<b>Dark mode tokens <em>now</em></b><small>Editing theme.css</small></div>
  <div class="gh" style="--c:${C.safe}">${dot("safe", true)} Safe to close <span>3</span></div>
  <div class="row" style="padding-bottom:10px">${dot("safe", true)}<b>Fix flaky login test <em>3h</em></b><small>Merged #208</small></div>
</div>`, caption);

export const safe = (caption) => plate(`<div class="w mid">
  ${chrome("Safe to close", '<span>⇧⌘X close all</span>')}
  <div class="row sel" style="--c:${C.safe};margin:7px">${dot("safe", true)}<b>Fix flaky login test <em>3h</em></b><small>robin/acme-41-login-flake · work</small>
    <ul class="checks">
      <li><i>✓</i><span>Nothing running, no background tasks</span><span>agents 15:02</span></li>
      <li><i>✓</i><span>Quiet for 3 h (needs 2 h)</span><span>events.jsonl</span></li>
      <li><i>✓</i><span>Last message asks nothing</span><span>reply rules</span></li>
      <li><i>✓</i><span>Git clean and pushed</span><span>git 15:01</span></li>
      <li><i>✓</i><span>PR #208 merged</span><span>gh 15:01</span></li>
      <li><i>✓</i><span>Haiku read: finished</span><span>$0.0002</span></li>
    </ul>
    <span class="btnm">Close</span> <span class="btnm" style="color:var(--dim)">Not safe</span>
  </div>
</div>`, caption);

export const keys = (caption) => plate(`<div class="stack">
  <div class="caps">
    <div class="cap"><div class="keys"><kbd>⌘</kbd><kbd>⌫</kbd></div><span>Delete to the start of the line</span></div>
    <div class="cap"><div class="keys"><kbd>⌥</kbd><kbd>⌫</kbd></div><span>Delete a word</span></div>
    <div class="cap"><div class="keys"><kbd>⌘</kbd><kbd>V</kbd></div><span>Paste a screenshot as an image</span></div>
  </div>
  <div class="w mid"><div class="scr"><span class="m">›</span> <span class="p">[Image #1]</span> the button sits under the header here <span class="cur"></span></div></div>
</div>`, caption);

export const plugins = (caption) => plate(`<div class="w lg"><div class="split2">
  <div>
    ${chrome("Acme")}
    <div class="gh" style="--c:${C.turn}">${dot("turn")} Your turn <span>2</span></div>
    <div class="row sel" style="--c:${C.turn}">${dot("turn")}<b>Billing totals <em>4m</em></b><small>PR #212 is open</small><span class="badge wa">ACME-56 · In Progress</span></div>
    <div class="row">${dot("turn")}<b>Reply to Mara <em>9m</em></b><small>Draft reply is ready</small><span class="badge">Slack · Mara</span></div>
    <div class="gh" style="--c:${C.safe}">${dot("safe", true)} Safe to close <span>1</span></div>
    <div class="row" style="padding-bottom:12px">${dot("safe", true)}<b>Fix flaky login test <em>3h</em></b><small>Merged #208</small><span class="badge ok">ACME-41 · Done</span></div>
  </div>
  <div>
    <div class="wh"><b>SLACK</b> <span>3</span><span class="sp"></span><span>LINEAR</span></div>
    <div class="gh" style="--c:${C.need}">Answer first</div>
    <div class="row">${dot("need")}<b>Mara <em>12m</em></b><small>Checkout is double-charging in EU</small><span class="btnm">Start Session</span></div>
    <div class="gh" style="--c:var(--dim)">Questions and requests</div>
    <div class="row">${dot("turn")}<b>Jonas <em>1h</em></b><small>Can you look at the pricing copy?</small></div>
    <div class="row" style="padding-bottom:12px">${dot("turn")}<b>#design <em>3h</em></b><small>Which icon set did we pick?</small></div>
  </div>
</div></div>`, caption);

export const linear = (caption) => plate(`<div class="w mid">
  ${chrome("Linear", '<span>⌥⌘6</span>')}
  <div class="gh" style="--c:${C.need}">Suggested <span>1</span></div>
  <div class="row sel" style="--c:${C.need}">${dot("need")}<b>ACME-56 Billing page totals <em></em></b><small>PR #212 merged · billing-totals</small><span class="btnm on">Move to Done</span> <span class="btnm" style="color:var(--dim)">Not now</span></div>
  <div class="gh" style="--c:var(--dim)">In progress <span>2</span></div>
  <div class="row">${dot("work")}<b>ACME-61 Invoice PDF export <em>1 session</em></b><small>In Progress</small></div>
  <div class="row" style="padding-bottom:12px">${dot("turn")}<b>ACME-64 Onboarding copy <em>1 needs you</em></b><small>In Progress</small></div>
</div>`, caption);

export const artifact = (caption) => plate(`<div class="w lg"><div class="split2">
  <div>
    <div class="wh"><b>Pricing page</b><span class="sp"></span><span class="acct">work</span></div>
    <div class="scr"><span class="m">⏺</span> Published the pricing draft.
  <span class="m">⎿</span> claude.ai/artifact/7c2e…

<span class="m">›</span> <span class="cur"></span></div>
  </div>
  <div>
    <div class="wh"><b>Pricing draft</b><span class="sp"></span><span class="acct"><i class="d" style="--c:${C.safe}"></i> work · signed in</span></div>
    <div class="md"><h5>Pricing</h5><p>Three plans, one table.</p><div class="bar t"></div><div class="bar"></div><div class="bar s"></div><div class="bar t"></div><div class="bar s"></div></div>
  </div>
</div></div>`, caption);

export const bringIn = (caption) => plate(`<div class="stack">
  <div class="w sm">
    <div class="row sel" style="--c:${C.turn};margin:7px">${dot("turn")}<b>Search index rebuild <em>read-only</em></b><small>Running in Terminal · pid 48211</small><span class="btnm on">Bring into Maxwell</span></div>
  </div>
  <div class="arrow">↓</div>
  <div class="w sm">
    <div class="row" style="margin:7px">${dot("turn")}<b>Search index rebuild <em>now</em></b><small>Same conversation · claude --bg --resume</small></div>
  </div>
</div>`, caption);

export const usage = (caption) => plate(`<div class="w mid">
  ${chrome("Usage")}
  <div class="ub">
    <span class="h">WORK</span>
    <span>5-hour</span><span class="t"><i style="width:82%" class="hot"></i></span><span class="n">82%</span>
    <small>resets 16:40</small>
    <span>Weekly</span><span class="t"><i style="width:47%"></i></span><span class="n">47%</span>
    <small>resets Thu 09:00</small>
  </div>
  <div class="ub" style="border-top:1px solid var(--line)">
    <span class="h">PERSONAL</span>
    <span>5-hour</span><span class="t"><i style="width:12%"></i></span><span class="n">12%</span>
    <small>resets 18:05</small>
    <span>Weekly</span><span class="t"><i style="width:21%"></i></span><span class="n">21%</span>
    <small>resets Mon 11:00</small>
  </div>
</div>`, caption);

export const rail = (caption) => plate(`<div class="w sm" style="max-width:300px">
  <div class="rail"><i class="on"><svg viewBox="0 0 7 7"><use href="#demon"/></svg></i><i class="on">AC</i><i>OR<b>2</b></i><i>BL</i><i style="border-style:dashed">+</i></div>
  <div style="padding:0 12px 12px;color:var(--faint);font-size:11px">⌘0 all · ⌘1 Acme · ⌘2 Orbit · ⌃⌘P show the rail</div>
</div>`, caption);

export const search = (caption) => plate(`<div class="w mid pal">
  <div class="q"><span>⌕</span><b>migr</b><span class="cur"></span></div>
  <ul>
    <li class="sel">${dot("need")} Billing totals <em>touched db/<mark>migr</mark>ations/0042.sql</em></li>
    <li>${dot("turn")} <span><mark>Migr</mark>ate auth to v2</span> <em>Orbit · personal</em></li>
    <li>${dot("safe", true)} Seed script <em>branch robin/<mark>migr</mark>ation-seed</em></li>
    <li><span style="color:var(--faint)">⌘K</span> Bring Terminal Sessions into Maxwell… <em>action</em></li>
  </ul>
  <footer>↑↓ move · ⏎ open · esc close</footer>
</div>`, caption);

export const panels = (caption) => plate(`<div class="w mid">
  ${chrome("Panels", "<span>⌘B · ⌥⌘B · ⌥⌘J</span>")}
  <div class="lay"><div class="s">Sessions</div><div class="m">Claude session</div><div>Viewer</div><div class="b">Usage · System · Plugins</div></div>
</div>`, caption);

export const pipeline = (caption) => plate(`<div class="pipe">
  <div class="src"><span class="n">Claude Code hooks</span><span class="n">status line tap</span><span class="n">claude agents</span></div>
  <span class="arrow">→</span><span class="n">events.jsonl</span><span class="arrow">→</span><span class="n k">reduce(State, Event)</span>
</div>`, caption);

export const launch = (caption) => plate(`<div class="stack">
  <div style="display:flex;gap:14px;align-items:center;color:var(--ink)"><svg viewBox="0 0 7 7" style="width:44px;height:44px"><use href="#demon"/></svg></div>
  <div class="w" style="max-width:520px;padding:6px 0">
    <div style="display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:0">
      ${[["need", "Needs you", 1], ["turn", "Your turn", 3], ["work", "Working", 4], ["limit", "Limited", 1], ["safe", "Safe to close", 6], ["work", "Idle", 12]]
        .map(([c, t, n], i) => `<div style="padding:12px 14px;${i % 3 ? "border-left:1px solid var(--line);" : ""}${i > 2 ? "border-top:1px solid var(--line);" : ""}"><span style="display:flex;gap:8px;align-items:center;color:${C[c]}">${dot(c, c === "safe" || t === "Idle")}${t}</span><span style="display:block;margin-top:4px;color:var(--faint);font-size:11px">${n} session${n === 1 ? "" : "s"}</span></div>`).join("")}
    </div>
  </div>
</div>`, caption);

export const wrapLine = (caption) => plate(`<div class="w lg"><div class="split2">
  <div>
    <div class="wh"><b>Billing totals</b><span class="sp"></span><span class="acct">work</span></div>
    <div class="scr"><span class="m">⏺</span> Merged #212 and moved ACME-56
  to Done. Nothing else is open.

  <span class="g">Safe to close</span> <span class="m">· PR merged, ticket done</span></div>
  </div>
  <div>
    <div class="gh" style="--c:${C.need};padding-top:12px">${dot("need")} Needs you <span>1</span></div>
    <div class="row">${dot("need")}<b>Invoice PDF export <em>1m</em></b><small><span style="color:var(--need)">Needs you</span> · pick a paper size</small></div>
    <div class="gh" style="--c:${C.turn}">${dot("turn")} Your turn <span>1</span></div>
    <div class="row">${dot("turn")}<b>Onboarding copy <em>8m</em></b><small>Not done · two screens left</small></div>
    <div class="gh" style="--c:${C.safe}">${dot("safe", true)} Safe to close <span>1</span></div>
    <div class="row sel" style="--c:${C.safe};margin-bottom:10px">${dot("safe", true)}<b>Billing totals <em>now</em></b><small>Safe to close · PR merged, ticket done</small></div>
  </div>
</div></div>`, caption);
