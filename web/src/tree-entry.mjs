// Bundled (offline) entry for the LGTM editor window's LEFT pane: a @pierre/trees
// file tree with git-status badges. esbuild inlines @pierre/trees (+ its preact
// dep + injected CSS) into one self-contained file — no runtime network.
import { FileTree } from '@pierre/trees';

let tree = null;
let lastGitStatus = [];           // remembered so a badge refresh can nudge a redraw
let commentCounts = {};           // path -> inline-thread count, for the comment badge
let agentEdits = new Set();       // paths the agent has edited this session, for the blue overlay
let agentAddedPaths = new Set();  // paths WE inserted (agent-created files absent from the open snapshot)

function host() {
  return document.getElementById('tree');
}

/// Decoration shown to the right of a file row: the number of review threads on
/// it. Read live (from `commentCounts`) so updates only need a cheap redraw, not a
/// full tree rebuild (which would drop expansion/scroll state). The agent-edits
/// highlight is NOT a decoration (those are text-only, no per-row color) — it's a
/// light-blue row overlay injected as shadow-DOM CSS (see applyAgentEditOverlay).
function renderRowDecoration({ item }) {
  if (!item || item.kind !== 'file') return null;
  const n = commentCounts[item.path];
  if (!n) return null;
  const count = n > 99 ? '99+' : String(n);
  return { text: count, title: `${n} comment${n === 1 ? '' : 's'}` };
}

/// Paint a light-blue wash over the rows of files the agent has edited this
/// session. @pierre/trees offers no per-row class/style hook and renders into a
/// shadow root that page CSS can't pierce — so we inject a <style> INTO that shadow
/// root, matching rows by their `data-item-path`. The colour is a CSS custom
/// property on `.tree-host` (light/dark), which inherits through the shadow
/// boundary. Re-run after every tree render (the shadow host is recreated) and on
/// every setAgentEdits.
function applyAgentEditOverlay(attempt = 0) {
  const el = host();
  if (!el) return;
  const container = el.querySelector('file-tree-container');
  const shadow = container && container.shadowRoot;
  if (!shadow) {
    // The web component may not have upgraded yet in the same frame as render().
    if (attempt < 10) requestAnimationFrame(() => applyAgentEditOverlay(attempt + 1));
    return;
  }
  let style = shadow.getElementById('lgtm-agent-edits');
  if (!style) {
    style = document.createElement('style');
    style.id = 'lgtm-agent-edits';
    shadow.appendChild(style);
  }
  const paths = [...agentEdits];
  if (!paths.length) { style.textContent = ''; return; }
  const sel = paths
    .map((p) => `button[data-type="item"][data-item-path="${cssAttrEscape(p)}"]`)
    .join(',');
  style.textContent = `${sel}{background-color:var(--trees-agent-edit-overlay,rgba(56,139,253,0.18));}`;
}

/// Escape a string for use inside a double-quoted CSS attribute-selector value.
function cssAttrEscape(s) {
  return String(s).replace(/[\\"]/g, '\\$&');
}

/// Fold agent-created files into the tree. The path list is snapshotted at window
/// open, so files the agent makes mid-session aren't in it — insert any agent-edited
/// path the tree doesn't already have (revealing its folders so it's actually
/// visible), and drop ones we added that the agent later deleted. Existing PR files
/// are matched by getItem and left alone, preserving the user's expand/scroll state.
function reconcileAgentPaths(paths) {
  if (!tree) return;
  const wanted = new Set(paths);
  for (const p of wanted) {
    if (tree.getItem(p)) continue;        // already present (a PR file or already added)
    try {
      tree.add(p);
      agentAddedPaths.add(p);
      revealAncestors(p);
    } catch (_) {}
  }
  for (const p of [...agentAddedPaths]) {
    if (wanted.has(p)) continue;          // still an agent edit — keep it
    try { tree.remove(p); } catch (_) {}
    agentAddedPaths.delete(p);
  }
}

/// Expand every ancestor directory of `path` so a newly added file isn't hidden
/// inside a collapsed folder. Expanding an already-open directory is a no-op.
function revealAncestors(path) {
  const parts = path.split('/');
  let acc = '';
  for (let i = 0; i < parts.length - 1; i += 1) {
    acc = acc ? `${acc}/${parts[i]}` : parts[i];
    const dir = tree.getItem(acc);
    if (dir && typeof dir.expand === 'function') {
      try { dir.expand(); } catch (_) {}
    }
  }
}

/// Render (or re-render) the whole tree. `paths` is a flat array of repo-relative
/// file paths; `gitStatus` is an array of { path, status } entries.
function renderTree(paths, gitStatus, selected) {
  const el = host();
  if (!el) return;
  if (tree) {
    try { tree.cleanUp(); } catch (_) {}
    tree = null;
  }
  el.replaceChildren();
  lastGitStatus = gitStatus || [];
  // Fresh tree from the snapshot paths — any agent files we'd inserted are gone, so
  // forget them; the next setAgentEdits re-adds whatever's still touched.
  agentAddedPaths = new Set();

  // Collapse the full repo tree by default, but auto-expand the directories that
  // contain a changed file — so the PR's changes are visible on open while the
  // rest of the repo stays tucked away (expand any folder to browse it). Passing
  // explicit `initialExpandedPaths` with 'closed' expands only those dirs;
  // 'open' with none would expand everything (the old wall-of-files). The tree
  // keys directories by their path with no trailing slash, so build each
  // changed file's ancestor dirs the same way.
  const expanded = new Set();
  for (const entry of gitStatus || []) {
    const parts = entry.path.split('/');
    let acc = '';
    for (let i = 0; i < parts.length - 1; i += 1) {
      acc = acc ? `${acc}/${parts[i]}` : parts[i];
      expanded.add(acc);
    }
  }

  tree = new FileTree({
    paths,
    gitStatus: gitStatus || [],
    flattenEmptyDirectories: false,
    initialExpansion: 'closed',
    initialExpandedPaths: [...expanded],
    search: true,
    icons: { set: 'standard', colored: true },
    renderRowDecoration,
    // Selection (click / keyboard). We forward only FILE selections to native.
    onSelectionChange(selectedPaths) {
      const path = selectedPaths[selectedPaths.length - 1];
      if (!path) return;
      const item = tree.getItem(path);
      if (item && !item.isDirectory()) {
        window.webkit?.messageHandlers?.fileSelected?.postMessage(path);
      }
    },
  });

  tree.render({ containerWrapper: el });

  if (selected) {
    try { tree.focusPath(selected); } catch (_) {}
  }

  // The shadow host was just recreated, so re-inject the agent-edits overlay.
  applyAgentEditOverlay();
}

/// Live-update just the git-status badges without rebuilding the tree.
function setGitStatus(gitStatus) {
  lastGitStatus = gitStatus || [];
  if (tree) {
    try { tree.setGitStatus(lastGitStatus); } catch (_) {}
  }
}

/// Update per-file comment-count badges. `counts` is a { path: number } map.
/// `renderRowDecoration` reads `commentCounts` live, so we just nudge a redraw by
/// re-applying the current git status (cheap; preserves expansion + scroll).
function setCommentCounts(counts) {
  commentCounts = counts || {};
  if (tree) {
    try { tree.setGitStatus(lastGitStatus); } catch (_) {}
  }
}

/// Update which files carry the light-blue "edited by the agent" overlay. `paths`
/// is a flat array. The overlay is pure shadow-DOM CSS keyed on the path, so we
/// just re-stamp the <style> — no tree rebuild, expansion/scroll untouched.
function setAgentEdits(paths) {
  agentEdits = new Set(Array.isArray(paths) ? paths : []);
  reconcileAgentPaths(agentEdits);
  applyAgentEditOverlay();
}

/// Follow the native window appearance. The tree's colors come from the
/// `--trees-*-override` CSS variables on `.tree-host` (see style.css), which the
/// `.theme-dark` class redefines — so toggling the class restyles the tree.
function setTheme(mode) {
  document.documentElement.classList.toggle('theme-dark', mode === 'dark');
}

window.LGTM = Object.assign(window.LGTM || {}, {
  renderTree,
  setGitStatus,
  setCommentCounts,
  setAgentEdits,
  setTheme,
  ready: true,
});

// Tell native the page is ready (covers the case where Swift's didFinish races
// the module graph).
window.webkit?.messageHandlers?.paneReady?.postMessage('tree');
