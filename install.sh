#!/usr/bin/env bash
#
# install.sh — Bootstrap a `gloocode` shell shortcut from a local clone of
# glooai/opencode. Works regardless of where you cloned the repo.
#
# What it does:
#   1. Preflight: verifies bun is on PATH (warns if version < 1.3.13, which
#      the pre-push hook requires; soft warning, not fatal). If `.env.local`
#      is missing, copies it from `.env.example`. Runs `bun install` if
#      `node_modules` is absent (skip with --skip-install).
#   2. Stable handle: symlinks `${XDG_DATA_HOME:-~/.local/share}/gloocode`
#      to this clone, so the rc function references a path that is stable
#      across machines and re-clones. Move the repo? Re-run install.sh to
#      update the symlink. Disable with --no-canonical (writes the raw clone
#      path into the rc instead).
#   3. Shell integration: appends (or, idempotently, replaces) a managed
#      function block in your shell rc. The function:
#        - keeps your current cwd as the workspace (does NOT cd into this repo)
#        - sources `<canonical>/.env.local` via absolute path so Gloo creds
#          are in env when the TUI starts
#        - launches `bun run --conditions=browser <canonical>/packages/opencode/src/index.ts "$@"`
#      so opencode treats *your project* as the workspace while still finding
#      the Gloo AI provider seed and OAuth creds from this clone.
#
# Idempotent: re-running this script replaces the managed block; it doesn't
# touch any unmanaged definitions you may have written by hand.
#
# Usage:
#   ./install.sh                           # install gloocode into the auto-detected rc
#   ./install.sh --name oc                 # name the function "oc" instead
#   ./install.sh --rc ~/.zprofile          # write into a non-default rc file
#   ./install.sh --canonical-path /path    # custom symlink location
#   ./install.sh --no-canonical            # skip symlink, hard-code clone path
#   ./install.sh --skip-install            # don't run `bun install`
#   ./install.sh --print                   # print the function block to stdout; no rc write
#   ./install.sh --uninstall               # remove the managed block + symlink
#   ./install.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$SCRIPT_DIR"

NAME="gloocode"
RC_FILE=""
PRINT_ONLY=0
SKIP_INSTALL=0
UNINSTALL=0
USE_CANONICAL=1
CANONICAL_DIR_OVERRIDE=""

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)            NAME="${2:?missing value for --name}"; shift 2 ;;
    --rc)              RC_FILE="${2:?missing value for --rc}"; shift 2 ;;
    --canonical-path)  CANONICAL_DIR_OVERRIDE="${2:?missing value for --canonical-path}"; USE_CANONICAL=1; shift 2 ;;
    --no-canonical)    USE_CANONICAL=0; shift ;;
    --print)           PRINT_ONLY=1; shift ;;
    --skip-install)    SKIP_INSTALL=1; shift ;;
    --uninstall)       UNINSTALL=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---- Resolve canonical path --------------------------------------------

DEFAULT_CANONICAL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/${NAME}"
if [[ -n "$CANONICAL_DIR_OVERRIDE" ]]; then
  CANONICAL_DIR="$CANONICAL_DIR_OVERRIDE"
else
  CANONICAL_DIR="$DEFAULT_CANONICAL_DIR"
fi

if [[ "$USE_CANONICAL" -eq 1 ]]; then
  FUNCTION_PATH="$CANONICAL_DIR"
else
  FUNCTION_PATH="$REPO_ROOT"
fi

# ---- Detect rc file -----------------------------------------------------

if [[ -z "$RC_FILE" ]]; then
  case "$(basename "${SHELL:-bash}")" in
    zsh)
      RC_FILE="$HOME/.zshrc"
      ;;
    bash)
      # On macOS, Terminal launches login shells, which read .bash_profile and
      # not .bashrc. Prefer the file that exists; default to .bashrc otherwise.
      if [[ -f "$HOME/.bash_profile" && ! -f "$HOME/.bashrc" ]]; then
        RC_FILE="$HOME/.bash_profile"
      else
        RC_FILE="$HOME/.bashrc"
      fi
      ;;
    *)
      RC_FILE="$HOME/.zshrc"
      ;;
  esac
fi

MARKER_BEGIN="# >>> ${NAME} (managed by glooai/opencode install.sh) >>>"
MARKER_END="# <<< ${NAME} <<<"

# ---- Compose the managed block -----------------------------------------
# `${NAME}` and `${FUNCTION_PATH}` expand at install time so the function
# captures the absolute path. `\$HOME`, `\$@`, and `\$_gloocode_repo` stay
# literal so they evaluate when the function is called.

read -r -d '' BLOCK <<EOF || true
$MARKER_BEGIN
# Launch the OpenCode TUI from your current cwd with the Gloo AI provider
# available. Stays in your invocation directory (so opencode treats that as
# the workspace) while sourcing creds and the dev entry from a stable handle
# pointing at the glooai/opencode clone: $FUNCTION_PATH
${NAME}() {
  local _gloocode_repo="$FUNCTION_PATH"
  if [ ! -d "\$_gloocode_repo" ]; then
    echo "error: \$_gloocode_repo missing — re-run \$_gloocode_repo/install.sh from your clone" >&2
    return 1
  fi
  (
    export PATH="\$HOME/.bun/bin:\$PATH"
    if [ -f "\$_gloocode_repo/.env.local" ]; then
      set -a; source "\$_gloocode_repo/.env.local"; set +a
    else
      echo "warning: \$_gloocode_repo/.env.local missing — Gloo AI provider will be unavailable" >&2
    fi
    bun run --conditions=browser "\$_gloocode_repo/packages/opencode/src/index.ts" "\$@"
  )
}
$MARKER_END
EOF

# ---- --print short-circuit ---------------------------------------------

if [[ "$PRINT_ONLY" -eq 1 ]]; then
  printf '%s\n' "$BLOCK"
  exit 0
fi

# ---- Helpers ------------------------------------------------------------

strip_managed_block() {
  local rc="$1"
  [[ -f "$rc" ]] || return 0
  if ! grep -qF "$MARKER_BEGIN" "$rc"; then
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
    $0 == b { skip=1; next }
    $0 == e { skip=0; next }
    !skip   { print }
  ' "$rc" > "$tmp"
  mv "$tmp" "$rc"
}

remove_canonical_symlink() {
  local target="$1"
  if [[ -L "$target" ]]; then
    rm "$target"
    echo "  ✓ removed symlink $target"
  elif [[ -e "$target" ]]; then
    echo "  ! $target exists but is not a symlink — leaving it untouched" >&2
  fi
}

# ---- --uninstall short-circuit -----------------------------------------

if [[ "$UNINSTALL" -eq 1 ]]; then
  echo "→ Uninstall"
  if [[ -f "$RC_FILE" ]] && grep -qF "$MARKER_BEGIN" "$RC_FILE"; then
    strip_managed_block "$RC_FILE"
    echo "  ✓ removed ${NAME} block from $RC_FILE"
  else
    echo "  · no managed ${NAME} block in $RC_FILE"
  fi
  remove_canonical_symlink "$CANONICAL_DIR"
  echo
  echo "Done. Open a new shell to drop the function from your environment."
  exit 0
fi

# ---- Preflight ----------------------------------------------------------

echo "→ Preflight"

if command -v bun >/dev/null 2>&1; then
  BUN_VERSION="$(bun --version)"
  echo "  ✓ bun ${BUN_VERSION} on PATH"
  REQUIRED="1.3.13"
  if [[ "$(printf '%s\n%s\n' "$REQUIRED" "$BUN_VERSION" | sort -V | head -n1)" != "$REQUIRED" ]]; then
    echo "  ! bun ${BUN_VERSION} < ${REQUIRED}; the repo's pre-push hook requires ${REQUIRED}+." >&2
    echo "    Upgrade: curl -fsSL https://bun.com/install | bash" >&2
  fi
else
  echo "  ! bun not found on PATH. Install with: curl -fsSL https://bun.com/install | bash" >&2
  echo "    The ${NAME} function adds \$HOME/.bun/bin to PATH automatically once bun is installed."
fi

if [[ -f "$REPO_ROOT/.env.local" ]]; then
  echo "  ✓ .env.local exists"
else
  if [[ -f "$REPO_ROOT/.env.example" ]]; then
    cp "$REPO_ROOT/.env.example" "$REPO_ROOT/.env.local"
    echo "  ! created .env.local from .env.example"
    echo "    Fill in GLOO_CLIENT_ID and GLOO_CLIENT_SECRET (Gloo Studio → Developer Console → OAuth Clients) before running ${NAME}." >&2
  else
    echo "  ! both .env.local and .env.example are missing — you'll need to create .env.local with your Gloo creds" >&2
  fi
fi

if [[ "$SKIP_INSTALL" -eq 0 ]]; then
  if [[ -d "$REPO_ROOT/node_modules" && -d "$REPO_ROOT/packages/opencode/node_modules" ]]; then
    echo "  ✓ node_modules present (skipping bun install)"
  else
    if command -v bun >/dev/null 2>&1; then
      echo "  → running bun install (this may take a minute)"
      ( cd "$REPO_ROOT" && bun install )
    else
      echo "  ! skipping bun install — bun not found"
    fi
  fi
fi

# ---- Canonical symlink --------------------------------------------------

if [[ "$USE_CANONICAL" -eq 1 ]]; then
  echo "→ Canonical handle"
  mkdir -p "$(dirname "$CANONICAL_DIR")"

  # Refuse to clobber a real directory at the canonical path.
  if [[ -e "$CANONICAL_DIR" && ! -L "$CANONICAL_DIR" ]]; then
    echo "  ! $CANONICAL_DIR exists and is not a symlink — refusing to overwrite." >&2
    echo "    Either move it aside or pass --canonical-path with a different location, or use --no-canonical." >&2
    exit 1
  fi

  # If existing symlink already targets us, no-op.
  if [[ -L "$CANONICAL_DIR" ]]; then
    current_target="$(readlink "$CANONICAL_DIR")"
    if [[ "$current_target" == "$REPO_ROOT" ]]; then
      echo "  ✓ $CANONICAL_DIR already points at $REPO_ROOT"
    else
      ln -snf "$REPO_ROOT" "$CANONICAL_DIR"
      echo "  ✓ updated symlink $CANONICAL_DIR → $REPO_ROOT (was $current_target)"
    fi
  else
    ln -snf "$REPO_ROOT" "$CANONICAL_DIR"
    echo "  ✓ created symlink $CANONICAL_DIR → $REPO_ROOT"
  fi
else
  echo "→ Canonical handle"
  echo "  · skipped (--no-canonical); rc will reference $REPO_ROOT directly"
fi

# ---- Warn about unmanaged duplicates -----------------------------------

if [[ -f "$RC_FILE" ]] && grep -Eq "^[[:space:]]*${NAME}[[:space:]]*\(\)|^[[:space:]]*alias[[:space:]]+${NAME}=" "$RC_FILE"; then
  if ! grep -qF "$MARKER_BEGIN" "$RC_FILE"; then
    echo "  ! detected an existing unmanaged definition of '${NAME}' in $RC_FILE" >&2
    echo "    The new managed block will be appended; the later definition wins, but you may want to remove the old one by hand." >&2
  fi
fi

# ---- Write the rc -------------------------------------------------------

echo "→ Shell integration"
mkdir -p "$(dirname "$RC_FILE")"
[[ -f "$RC_FILE" ]] || touch "$RC_FILE"

strip_managed_block "$RC_FILE"

{
  if [[ -s "$RC_FILE" ]] && [[ -n "$(tail -c1 "$RC_FILE" 2>/dev/null || true)" ]]; then
    printf '\n'
  fi
  printf '\n'
  printf '%s\n' "$BLOCK"
} >> "$RC_FILE"

echo "  ✓ wrote managed ${NAME} block to $RC_FILE"

case "$(basename "${SHELL:-bash}")" in
  zsh)  zsh -n "$RC_FILE" 2>/dev/null && echo "  ✓ rc syntax OK" || echo "  ! syntax check failed; please review $RC_FILE" >&2 ;;
  bash) bash -n "$RC_FILE" 2>/dev/null && echo "  ✓ rc syntax OK" || echo "  ! syntax check failed; please review $RC_FILE" >&2 ;;
  *)    : ;;
esac

cat <<DONE

Done. To use ${NAME} now in this shell:

  source $RC_FILE
  ${NAME}

Or open a new terminal. From any directory, just run \`${NAME}\` to launch the
OpenCode TUI with your project's cwd as the workspace and the Gloo AI provider
available in the model picker.

To remove later: $REPO_ROOT/install.sh --uninstall
DONE
