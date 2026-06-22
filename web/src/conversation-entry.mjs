// Bundled (offline) entry for the LGTM editor window's CONVERSATION tab (middle
// column, behind the [Diff] [Conversation] toggle). Shows what isn't anchored to
// a diff line — submitted-review summaries and general PR comments as a
// chronological timeline — plus an inline-comments-by-file roll-up so every
// thread (resolved, outdated, or drifted off its line) is reachable from one
// place. Comment bodies are server-rendered GitHub HTML; this pane only injects
// it (scripts are disabled in the WKWebView).
import { buildThread, relativeTime, postIntent, showThreadError, setSkills } from './thread.mjs';

function log(msg) {
  try { window.webkit?.messageHandlers?.lgtmLog?.postMessage('[conv] ' + msg); } catch (_) {}
}
window.addEventListener('error', (e) => log('ERR ' + (e.message || '') + ' @ ' + (e.filename || '') + ':' + (e.lineno || 0)));

let lastPayload = null;

function host() { return document.getElementById('conversation'); }

function placeholder(message, kind) {
  const el = host();
  if (!el) return;
  el.replaceChildren();
  const d = document.createElement('div');
  d.className = 'lgtm-empty' + (kind ? ` lgtm-${kind}` : '');
  d.textContent = message;
  el.appendChild(d);
}

/// Reviews worth showing: a verdict (approve/request-changes/dismiss) always
/// counts; a plain "commented"/"pending" review only counts if it carries a body
/// (GitHub emits an empty COMMENTED review whenever inline comments are left).
function meaningfulReview(r) {
  if (r.state === 'approved' || r.state === 'changes_requested' || r.state === 'dismissed') return true;
  return (r.bodyHTML || '').trim().length > 0;
}

const REVIEW_VERB = {
  approved: 'approved these changes',
  changes_requested: 'requested changes',
  dismissed: 'dismissed a review',
  commented: 'reviewed',
  pending: 'has a pending review',
};

function timelineItem({ author, avatarUrl, when, verb, badgeKind, badgeText, bodyHTML }) {
  const el = document.createElement('div');
  el.className = 'timeline-item';

  const head = document.createElement('div');
  head.className = 'timeline-head';
  head.appendChild(avatar(author, avatarUrl));
  const who = document.createElement('span');
  who.className = 'comment-author';
  who.textContent = author || 'ghost';
  head.appendChild(who);
  const v = document.createElement('span');
  v.className = 'timeline-verb';
  v.textContent = ' ' + verb;
  head.appendChild(v);
  if (badgeText) {
    const b = document.createElement('span');
    b.className = `badge badge-${badgeKind}`;
    b.textContent = badgeText;
    head.appendChild(b);
  }
  const time = document.createElement('span');
  time.className = 'comment-time';
  time.textContent = relativeTime(when);
  head.appendChild(time);
  el.appendChild(head);

  if ((bodyHTML || '').trim().length) {
    const body = document.createElement('div');
    body.className = 'comment-body';
    body.innerHTML = bodyHTML;
    el.appendChild(body);
  }
  return el;
}

function avatar(author, avatarUrl) {
  if (avatarUrl) {
    const img = document.createElement('img');
    img.className = 'avatar';
    img.src = avatarUrl; img.alt = author || ''; img.loading = 'lazy';
    img.addEventListener('error', () => {
      const m = document.createElement('span');
      m.className = 'avatar avatar-monogram';
      m.textContent = (author || '?').charAt(0).toUpperCase();
      img.replaceWith(m);
    }, { once: true });
    return img;
  }
  const m = document.createElement('span');
  m.className = 'avatar avatar-monogram';
  m.textContent = (author || '?').charAt(0).toUpperCase();
  return m;
}

function sectionTitle(text) {
  const h = document.createElement('div');
  h.className = 'section-title';
  h.textContent = text;
  return h;
}

function renderConversation(payload) {
  lastPayload = payload;
  const el = host();
  if (!el) return;

  if (payload.state === 'loading') { placeholder('Loading comments…', 'loading'); return; }
  if (payload.state === 'error') { placeholder(payload.error || 'Couldn’t load comments.', 'error'); return; }

  const reviews = (payload.reviews || []).filter(meaningfulReview);
  const comments = payload.comments || [];
  const files = payload.files || [];
  const inline = new Set(payload.inlineThreadIDs || []);

  if (!reviews.length && !comments.length && !files.length) {
    placeholder('No comments on this PR yet.', 'empty');
    return;
  }

  el.replaceChildren();

  // ---- Timeline: reviews + general comments, oldest first. ----
  const events = [];
  for (const r of reviews) {
    events.push({
      ts: Date.parse(r.submittedAt || '') || 0,
      node: timelineItem({
        author: r.author, avatarUrl: r.avatarUrl, when: r.submittedAt,
        verb: REVIEW_VERB[r.state] || 'reviewed',
        badgeKind: r.state === 'approved' ? 'approved'
          : r.state === 'changes_requested' ? 'changes' : null,
        badgeText: r.state === 'approved' ? 'Approved'
          : r.state === 'changes_requested' ? 'Changes requested' : null,
        bodyHTML: r.bodyHTML,
      }),
    });
  }
  for (const c of comments) {
    events.push({
      ts: Date.parse(c.createdAt || '') || 0,
      node: timelineItem({
        author: c.author, avatarUrl: c.avatarUrl, when: c.createdAt,
        verb: 'commented', bodyHTML: c.bodyHTML,
      }),
    });
  }
  events.sort((a, b) => a.ts - b.ts);
  if (events.length) {
    el.appendChild(sectionTitle('Conversation'));
    const timeline = document.createElement('div');
    timeline.className = 'timeline';
    for (const e of events) timeline.appendChild(e.node);
    el.appendChild(timeline);
  }

  // ---- Inline comments grouped by file (the never-disappear backstop). ----
  if (files.length) {
    el.appendChild(sectionTitle('Inline comments'));
    for (const file of files) {
      const group = document.createElement('div');
      group.className = 'file-group';
      const header = document.createElement('div');
      header.className = 'file-group-header';
      header.textContent = file.path;
      group.appendChild(header);
      for (const thread of file.threads || []) {
        const canJump = payload.headMatches && inline.has(thread.id) && thread.line != null;
        group.appendChild(buildThread(thread, {
          canJump,
          onJump: () => postIntent({ action: 'jump', threadId: thread.id, path: file.path, line: thread.line }),
        }));
      }
      el.appendChild(group);
    }
  }
}

function setTheme(mode) {
  document.documentElement.classList.toggle('theme-dark', mode === 'dark');
}

function commentError(threadId, payload) {
  const el = host();
  if (el) showThreadError(el, threadId, (payload && payload.message) || 'Something went wrong.');
}

window.LGTM = Object.assign(window.LGTM || {}, {
  renderConversation,
  setTheme,
  commentError,
  setSkills,
  ready: true,
});

placeholder('Loading comments…', 'loading');
window.webkit?.messageHandlers?.paneReady?.postMessage('conversation');
