// Bundled (offline) entry for the LGTM editor window's MIDDLE pane: a
// @pierre/diffs split diff, syntax-highlighted by Shiki in a LIGHT theme.
// esbuild (without code-splitting) inlines @pierre/diffs AND all of Shiki's
// bundled grammars/themes — and the JS regex engine ('shiki-js') needs no WASM —
// so the rendered diff is fully self-contained and offline.
import { FileDiff, preloadHighlighter, getFiletypeFromFileName } from '@pierre/diffs';

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
let lastArgs = null;   // last renderDiff input, so a theme switch can re-render it

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

/// Render the diff for one file. The native side sends `path` (the repo-relative
/// file path); `oldText`/`newText` are the before/after contents (either may be
/// null for added/deleted); `binary` short-circuits.
async function renderDiff({ path, oldText, newText, binary }) {
  lastArgs = { path, oldText, newText, binary };
  const name = path;
  const el = host();
  if (!el) return false;

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

  try {
    current = new FileDiff({
      theme: THEME,
      themeType,                 // 'light' | 'dark' branch of CSS light-dark()
      diffStyle: 'split',
      preferredHighlighter: 'shiki-js',
    });
    current.render({
      oldFile: { name, contents: oldText ?? '' },
      newFile: { name, contents: newText ?? '' },
      containerWrapper: el,
    });
  } catch (e) {
    log('render threw: ' + (e && (e.message || e)));
    placeholder(`${name} — failed to render diff`);
    return false;
  }
  return true;
}

/// Switch the diff theme to match the native window appearance and re-render the
/// current file (if any) so the change is immediate.
function setTheme(mode) {
  const dark = mode === 'dark';
  THEME = dark ? 'github-dark' : 'github-light';
  themeType = dark ? 'dark' : 'light';
  document.documentElement.classList.toggle('theme-dark', dark);
  if (lastArgs) renderDiff(lastArgs);
}

window.LGTM = Object.assign(window.LGTM || {}, {
  renderDiff,
  setTheme,
  showPlaceholder: placeholder,
  ready: true,
});

placeholder('Select a file to view its diff');
window.webkit?.messageHandlers?.paneReady?.postMessage('diff');
