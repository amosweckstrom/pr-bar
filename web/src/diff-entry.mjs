// Bundled (offline) entry for the LGTM editor window's MIDDLE pane: a
// @pierre/diffs split diff, syntax-highlighted by Shiki in a LIGHT theme.
// esbuild (without code-splitting) inlines @pierre/diffs AND all of Shiki's
// bundled grammars/themes — and the JS regex engine ('shiki-js') needs no WASM —
// so the rendered diff is fully self-contained and offline.
//
// On top of the diff, inline review threads are placed as @pierre/diffs line
// annotations: native passes the file's anchored threads to renderDiff/setThreads
// and `renderAnnotation` builds each thread's DOM via the shared thread.mjs.
import { FileDiff, File, preloadHighlighter, getFiletypeFromFileName } from '@pierre/diffs';
import { buildThread, showThreadError, setSkills } from './thread.mjs';

function log(msg) {
  try { window.webkit?.messageHandlers?.lgtmLog?.postMessage('[diff] ' + msg); } catch (_) {}
}
window.addEventListener('error', (e) => log('ERR ' + (e.message || '') + ' @ ' + (e.filename || '') + ':' + (e.lineno || 0)));
window.addEventListener('unhandledrejection', (e) => log('REJ ' + (e.reason && (e.reason.message || e.reason))));

// Theme is switchable at runtime: native calls window.LGTM.setTheme('dark'|'light')
// to follow the system appearance, and we re-render the current file in the new
// Shiki theme. Both themes are bundled, so the switch stays fully offline.
let THEME = 'github-light';
let themeType = 'light';
let current = null;
let currentIsSplit = false; // true when `current` is a FileDiff (split), false for a File
let lastArgs = null;     // last renderDiff input, so a theme switch can re-render it
let currentThreads = []; // anchored threads for the file on screen
let lastMode = 'pr';     // 'pr' (reviewed diff) | 'agent' (blue session edits)

function host() {
  return document.getElementById('diff');
}

function placeholder(message) {
  const el = host();
  if (!el) return;
  el.replaceChildren();
  const d = document.createElement('div');
  d.className = 'lgtm-empty';
  d.textContent = message;
  el.appendChild(d);
}

/// Map our bridge threads to @pierre/diffs line annotations. LEFT (base/old)
/// threads sit on the 'deletions' side, RIGHT (head/new) on 'additions'. Only
/// threads with a concrete line are placed (native already gated these).
function annotationsFor(threads) {
  const out = [];
  for (const t of threads || []) {
    if (t.line == null) continue;
    out.push({ side: t.side === 'left' ? 'deletions' : 'additions', lineNumber: t.line, metadata: t });
  }
  return out;
}

/// The annotation array in the shape the current component expects: a split
/// `FileDiff` keys by side; a sideless `File` (unchanged file) keys by line only.
function annotationsForCurrent(threads) {
  const annos = annotationsFor(threads);
  return currentIsSplit ? annos : annos.map((a) => ({ lineNumber: a.lineNumber, metadata: a.metadata }));
}

function renderAnnotation(annotation) {
  const thread = annotation.metadata;
  if (!thread) return undefined;
  const wrapper = document.createElement('div');
  wrapper.className = 'inline-thread';
  // Show the comment on its line by default; the caret still collapses it.
  wrapper.appendChild(buildThread(thread, { canJump: false, expandByDefault: true }));
  return wrapper;
}

/// Render the diff for one file. `fd` is the native FileDiff payload (path,
/// oldText, newText, binary). `threads` (optional) are the anchored review
/// threads for this file, placed inline. `mode` is 'pr' (reviewed diff, green/red)
/// or 'agent' (the agent's session edits, recolored blue via the `.agent-diff`
/// class); omitted on internal re-renders, which keep the last mode.
async function renderDiff(fd, threads, mode) {
  const { path, oldText, newText, binary } = fd;
  lastArgs = fd;
  currentThreads = threads || [];
  if (mode) lastMode = mode;
  const name = path;
  const el = host();
  if (!el) return false;
  el.classList.toggle('agent-diff', lastMode === 'agent');

  if (current) {
    try { current.cleanUp(); } catch (_) {}
    current = null;
  }
  el.replaceChildren();

  if (binary) {
    placeholder(`${name} — binary file, not shown`);
    return true;
  }

  const lang = getFiletypeFromFileName(name) || 'text';
  // Warm the highlighter so the first paint is already colored (it otherwise
  // paints plain then re-renders). Bundled langs/themes ⇒ no network.
  try {
    await preloadHighlighter({ themes: [THEME], langs: [lang], preferredHighlighter: 'shiki-js' });
  } catch (e) {
    log('preload failed: ' + (e && (e.message || e)));
  }

  const annotations = annotationsFor(currentThreads);

  // No diff to show — the file is unchanged by the PR, so the before/after sides
  // are identical. @pierre/diffs renders zero hunks for identical sides, which
  // looks blank; instead render the file itself (syntax-highlighted, no +/-
  // gutters) so the whole tree stays browsable, not just the changed files.
  if ((oldText ?? '') === (newText ?? '')) {
    try {
      currentIsSplit = false;
      current = new File({
        theme: THEME,
        themeType,               // 'light' | 'dark' branch of CSS light-dark()
        preferredHighlighter: 'shiki-js',
        renderAnnotation,
      });
      current.render({
        file: { name, contents: newText ?? oldText ?? '' },
        containerWrapper: el,
        // A File has no sides; map every annotation to its plain line number.
        lineAnnotations: annotations.map((a) => ({ lineNumber: a.lineNumber, metadata: a.metadata })),
      });
    } catch (e) {
      log('file render threw: ' + (e && (e.message || e)));
      placeholder(`${name} — failed to render file`);
      return false;
    }
    return true;
  }

  try {
    currentIsSplit = true;
    current = new FileDiff({
      theme: THEME,
      themeType,                 // 'light' | 'dark' branch of CSS light-dark()
      diffStyle: 'split',
      preferredHighlighter: 'shiki-js',
      renderAnnotation,
    });
    current.render({
      oldFile: { name, contents: oldText ?? '' },
      newFile: { name, contents: newText ?? '' },
      containerWrapper: el,
      lineAnnotations: annotations,
    });
  } catch (e) {
    log('render threw: ' + (e && (e.message || e)));
    placeholder(`${name} — failed to render diff`);
    return false;
  }
  return true;
}

/// Update just the inline threads on the current file (e.g. after a poll or a
/// reply). Uses the component's in-place setLineAnnotations — which appends/removes
/// only the changed annotation nodes and leaves the diff body (and the user's scroll
/// position) untouched. A full renderDiff() would replaceChildren and jump the view
/// back to the top on every poll. Falls back to a re-render only if that's
/// unavailable (e.g. nothing rendered yet).
function setThreads(threads) {
  currentThreads = threads || [];
  if (current && typeof current.setLineAnnotations === 'function') {
    try {
      current.setLineAnnotations(annotationsForCurrent(currentThreads));
      return;
    } catch (e) {
      log('setLineAnnotations failed: ' + (e && (e.message || e)));
    }
  }
  if (lastArgs) renderDiff(lastArgs, currentThreads);
}

/// Scroll to (and flash) a thread's anchor line — used by "jump to line".
function scrollToThread(threadId) {
  const el = host();
  if (!el) return;
  const node = el.querySelector(`.thread[data-thread-id="${cssEscape(threadId)}"]`);
  if (node) {
    node.scrollIntoView({ block: 'center', behavior: 'smooth' });
    node.classList.add('thread-flash');
    setTimeout(() => node.classList.remove('thread-flash'), 1200);
  }
}

function cssEscape(s) {
  if (window.CSS && CSS.escape) return CSS.escape(s);
  return String(s).replace(/["\\]/g, '\\$&');
}

function commentError(threadId, payload) {
  const el = host();
  if (el) showThreadError(el, threadId, (payload && payload.message) || 'Something went wrong.');
}

/// Switch the diff theme to match the native window appearance and re-render the
/// current file (if any) so the change is immediate.
function setTheme(mode) {
  const dark = mode === 'dark';
  THEME = dark ? 'github-dark' : 'github-light';
  themeType = dark ? 'dark' : 'light';
  document.documentElement.classList.toggle('theme-dark', dark);
  if (lastArgs) renderDiff(lastArgs, currentThreads);
}

window.LGTM = Object.assign(window.LGTM || {}, {
  renderDiff,
  setThreads,
  scrollToThread,
  commentError,
  setTheme,
  setSkills,
  showPlaceholder: placeholder,
  ready: true,
});

placeholder('Select a file to view its diff');
window.webkit?.messageHandlers?.paneReady?.postMessage('diff');
