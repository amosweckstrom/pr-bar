// Shared DOM builder for one PR review thread, used in BOTH web contexts: the
// diff pane's `renderAnnotation` (inline, anchored to a line) and the
// conversation pane's inline-by-file roll-up. Keeping the thread DOM in one
// module is the whole point — the two surfaces must not drift.
//
// esbuild inlines this into each entry bundle separately, so the module-level
// `uiState` map below is PER PANE: the diff pane and conversation pane track
// their own expansion/draft independently, which is what we want.

/// Per-thread UI state that must survive a full re-render (native re-pushes the
/// whole conversation after every poll/write). Keyed by thread id.
const uiState = new Map();

function state(threadId) {
  let s = uiState.get(threadId);
  if (!s) { s = { expanded: null, draft: '' }; uiState.set(threadId, s); }
  return s;
}

export function escapeHtml(s) {
  return String(s ?? '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

/// Compact relative time ("3h", "2d") from an ISO string; falls back to the
/// raw date for anything older than a few weeks, and to '' when absent.
export function relativeTime(iso) {
  if (!iso) return '';
  const then = Date.parse(iso);
  if (Number.isNaN(then)) return '';
  const secs = Math.max(0, (Date.now() - then) / 1000);
  if (secs < 60) return 'just now';
  const mins = Math.floor(secs / 60); if (mins < 60) return `${mins}m`;
  const hrs = Math.floor(mins / 60); if (hrs < 24) return `${hrs}h`;
  const days = Math.floor(hrs / 24); if (days < 21) return `${days}d`;
  try { return new Date(then).toLocaleDateString(); } catch (_) { return `${days}d`; }
}

/// Post a reply/resolve/jump/dirty/fixWithAI intent to native. The native
/// controller owns all conversation state and re-renders us; we never mutate
/// state locally.
export function postIntent(intent) {
  try { window.webkit?.messageHandlers?.commentIntent?.postMessage(intent); } catch (_) {}
}

/// Installed "Fix with AI" skills ([{id, name}]), pushed by native via setSkills.
/// Read live when each comment's button is built; native pushes this before the
/// first comment renders.
let skills = [];
export function setSkills(list) { skills = Array.isArray(list) ? list : []; }

/// The per-comment "Fix with AI" control: with one skill it fires directly; with
/// several it opens a small menu of skill names. Returns null when no skills are
/// installed. The chosen skill is rendered (native side) against this comment and
/// injected into the agent running in the terminal pane.
function fixWithAIControl(threadId, commentId) {
  if (!skills.length) return null;
  const wrap = document.createElement('span');
  wrap.className = 'comment-fixai-wrap';

  const btn = document.createElement('button');
  btn.type = 'button';
  btn.className = 'comment-fixai';
  btn.textContent = 'Fix with AI';
  btn.title = 'Send this comment to the agent in the terminal';
  wrap.appendChild(btn);

  const fire = (skillId) => postIntent({ action: 'fixWithAI', threadId, commentId, skillId });

  if (skills.length === 1) {
    btn.addEventListener('click', (e) => { e.stopPropagation(); fire(skills[0].id); });
    return wrap;
  }

  btn.addEventListener('click', (e) => {
    e.stopPropagation();
    const existing = wrap.querySelector('.fixai-menu');
    if (existing) { existing.remove(); return; }
    const menu = document.createElement('div');
    menu.className = 'fixai-menu';
    for (const s of skills) {
      const item = document.createElement('button');
      item.type = 'button';
      item.className = 'fixai-menu-item';
      item.textContent = s.name;
      item.addEventListener('click', (ev) => { ev.stopPropagation(); menu.remove(); fire(s.id); });
      menu.appendChild(item);
    }
    wrap.appendChild(menu);
    // Dismiss on the next outside click.
    const close = (ev) => {
      if (!wrap.contains(ev.target)) { menu.remove(); document.removeEventListener('click', close); }
    };
    setTimeout(() => document.addEventListener('click', close), 0);
  });
  return wrap;
}

function avatarNode(author, avatarUrl) {
  if (avatarUrl) {
    const img = document.createElement('img');
    img.className = 'avatar';
    img.src = avatarUrl;
    img.alt = author || '';
    img.loading = 'lazy';
    // Fall back to a monogram if the avatar fails to load (offline, 404).
    img.addEventListener('error', () => img.replaceWith(monogram(author)), { once: true });
    return img;
  }
  return monogram(author);
}

function monogram(author) {
  const span = document.createElement('span');
  span.className = 'avatar avatar-monogram';
  span.textContent = (author || '?').charAt(0).toUpperCase();
  return span;
}

function commentNode(comment, { pending, threadId } = {}) {
  const el = document.createElement('div');
  el.className = 'comment' + (pending ? ' comment-pending' : '');

  const head = document.createElement('div');
  head.className = 'comment-head';
  head.appendChild(avatarNode(comment.author, comment.avatarUrl));
  const who = document.createElement('span');
  who.className = 'comment-author';
  who.textContent = comment.author || 'ghost';
  head.appendChild(who);
  const when = document.createElement('span');
  when.className = 'comment-time';
  when.textContent = pending ? 'sending…' : relativeTime(comment.createdAt);
  head.appendChild(when);
  // "Fix with AI" hands this comment to the terminal agent. Skipped for in-flight
  // optimistic comments (no real id yet) and when no skills are installed.
  if (!pending && threadId) {
    const fix = fixWithAIControl(threadId, comment.id);
    if (fix) head.appendChild(fix);
  }
  el.appendChild(head);

  const body = document.createElement('div');
  body.className = 'comment-body';
  body.innerHTML = comment.bodyHTML || '';   // server-sanitized GitHub HTML
  el.appendChild(body);
  return el;
}

/// Build the DOM for one thread.
/// `opts.canJump` shows a "jump to line" affordance (conversation pane only);
/// `opts.onJump()` is invoked when it's clicked.
export function buildThread(thread, opts = {}) {
  const s = state(thread.id);
  // Inline diff annotations pass `expandByDefault` so the comment shows on its line
  // without a click (the whole point of an inline annotation); the conversation
  // roll-up leaves resolved/outdated threads collapsed by default to cut noise.
  // Either way the caret still toggles, and a user's explicit toggle pins it.
  const collapsedByDefault = opts.expandByDefault ? false : (thread.isResolved || thread.isOutdated);
  // `expanded === null` means "use the default"; a user toggle pins it.
  const expanded = s.expanded === null ? !collapsedByDefault : s.expanded;
  const pendingDraft = (s.draft || '').length > 0;

  const root = document.createElement('div');
  root.className = 'thread';
  root.dataset.threadId = thread.id;
  if (thread.isResolved) root.classList.add('thread-resolved');
  if (thread.isOutdated) root.classList.add('thread-outdated');

  // Summary row (always present; doubles as the expand/collapse control).
  const summary = document.createElement('button');
  summary.className = 'thread-summary';
  summary.type = 'button';
  const caret = document.createElement('span');
  caret.className = 'thread-caret';
  caret.textContent = expanded ? '▾' : '▸';
  summary.appendChild(caret);

  if (thread.isResolved) summary.appendChild(badge('Resolved', 'resolved'));
  if (thread.isOutdated) summary.appendChild(badge('Outdated', 'outdated'));

  const count = (thread.comments || []).length;
  const label = document.createElement('span');
  label.className = 'thread-summary-text';
  const first = (thread.comments || [])[0];
  const firstAuthor = first ? (first.author || 'ghost') : 'thread';
  label.textContent = `${firstAuthor} · ${count} comment${count === 1 ? '' : 's'}`;
  summary.appendChild(label);

  if (opts.canJump) {
    const jump = document.createElement('span');
    jump.className = 'thread-jump';
    jump.textContent = 'jump to line';
    jump.addEventListener('click', (e) => { e.stopPropagation(); opts.onJump?.(); });
    summary.appendChild(jump);
  }

  summary.addEventListener('click', () => {
    s.expanded = !expanded;
    const next = buildThread(thread, opts);
    root.replaceWith(next);
  });
  root.appendChild(summary);

  // Body (comments + composer + error), hidden when collapsed.
  const body = document.createElement('div');
  body.className = 'thread-body';
  body.hidden = !expanded;

  for (const c of thread.comments || []) {
    const pending = String(c.id).startsWith('optimistic-');
    body.appendChild(commentNode(c, { pending, threadId: thread.id }));
  }

  const actions = document.createElement('div');
  actions.className = 'thread-actions';
  const resolveBtn = document.createElement('button');
  resolveBtn.type = 'button';
  resolveBtn.className = 'thread-action-btn';
  resolveBtn.textContent = thread.isResolved ? 'Unresolve' : 'Resolve';
  resolveBtn.addEventListener('click', () => {
    postIntent({ action: thread.isResolved ? 'unresolve' : 'resolve', threadId: thread.id });
  });
  actions.appendChild(resolveBtn);
  body.appendChild(actions);

  // Composer.
  const composer = document.createElement('div');
  composer.className = 'composer';
  const ta = document.createElement('textarea');
  ta.className = 'composer-input';
  ta.rows = 2;
  ta.placeholder = 'Reply…';
  ta.value = s.draft || '';
  ta.addEventListener('input', () => {
    s.draft = ta.value;
    postIntent({ action: 'dirty', threadId: thread.id, dirty: ta.value.length > 0 });
  });
  ta.addEventListener('focus', () => postIntent({ action: 'dirty', threadId: thread.id, dirty: true }));
  ta.addEventListener('blur', () => {
    if (!ta.value.length) postIntent({ action: 'dirty', threadId: thread.id, dirty: false });
  });
  // Cmd/Ctrl+Enter submits.
  ta.addEventListener('keydown', (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') { e.preventDefault(); submit(); }
  });
  composer.appendChild(ta);

  const err = document.createElement('div');
  err.className = 'thread-error';
  err.hidden = true;
  composer.appendChild(err);

  const replyBtn = document.createElement('button');
  replyBtn.type = 'button';
  replyBtn.className = 'composer-submit';
  replyBtn.textContent = 'Reply';
  replyBtn.addEventListener('click', submit);
  composer.appendChild(replyBtn);

  function submit() {
    const text = ta.value.trim();
    if (!text) return;
    postIntent({ action: 'reply', threadId: thread.id, body: text });
    s.draft = '';
    ta.value = '';
    postIntent({ action: 'dirty', threadId: thread.id, dirty: false });
  }

  body.appendChild(composer);
  root.appendChild(body);

  // Re-show an open draft even on a collapsed thread (don't lose typed text).
  if (!expanded && pendingDraft) body.hidden = false;
  return root;
}

function badge(text, kind) {
  const b = document.createElement('span');
  b.className = `badge badge-${kind}`;
  b.textContent = text;
  return b;
}

/// Surface a write failure on the matching thread, wherever it's rendered.
export function showThreadError(rootEl, threadId, message) {
  const thread = rootEl.querySelector(`.thread[data-thread-id="${cssEscape(threadId)}"]`);
  if (!thread) return;
  const body = thread.querySelector('.thread-body');
  if (body) body.hidden = false;
  const err = thread.querySelector('.thread-error');
  if (err) { err.textContent = message; err.hidden = false; }
}

function cssEscape(s) {
  if (window.CSS && CSS.escape) return CSS.escape(s);
  return String(s).replace(/["\\]/g, '\\$&');
}
