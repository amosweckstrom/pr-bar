// Bundled (offline) entry for the LGTM editor window's LEFT pane: a @pierre/trees
// file tree with git-status badges. esbuild inlines @pierre/trees (+ its preact
// dep + injected CSS) into one self-contained file — no runtime network.
import { FileTree } from '@pierre/trees';

let tree = null;

function host() {
  return document.getElementById('tree');
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
}

/// Live-update just the badges without rebuilding the tree.
function setGitStatus(gitStatus) {
  if (tree) {
    try { tree.setGitStatus(gitStatus || []); } catch (_) {}
  }
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
  setTheme,
  ready: true,
});

// Tell native the page is ready (covers the case where Swift's didFinish races
// the module graph).
window.webkit?.messageHandlers?.paneReady?.postMessage('tree');
