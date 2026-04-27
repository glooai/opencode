#!/usr/bin/env bash
#
# install.sh — Bootstrap a `gloocode` shell shortcut from a local clone of
# glooai/opencode. Works regardless of where you cloned the repo.
#
# What it does:
#   1. Preflight: verifies bun is on PATH (warns if version < 1.3.13, which
#      the pre-push hook requires; soft warning, not fatal). Runs `bun install`
#      if `node_modules` is absent (skip with --skip-install).
#   2. Stable handle: symlinks `${XDG_DATA_HOME:-~/.local/share}/gloocode`
#      to this clone, so the rc function references a path that is stable
#      across machines and re-clones. Move the repo? Re-run install.sh to
#      update the symlink. Disable with --no-canonical (writes the raw clone
#      path into the rc instead).
#   3. Auth (interactive): if no Gloo credentials are saved, opens
#      https://studio.ai.gloo.com/api-credentials in your browser, prompts
#      you to paste the client ID and client secret separately (both hidden,
#      no shell-history leak), validates them with a live OAuth2
#      client_credentials grant, then persists them to a 0600-mode file at
#      `${XDG_CONFIG_HOME:-~/.config}/gloocode/credentials` with a refresh
#      timestamp. The credential file is sourceable shell so the gloocode
#      function loads it with `source` — no JSON parser dependency. A TTL
#      (default 90 days) drives a soft hygiene warning, not an enforcement;
#      Gloo platform credentials are long-lived API keys.
#   4. Shell integration: appends (or, idempotently, replaces) a managed
#      function block in your shell rc. The function:
#        - keeps your current cwd as the workspace (does NOT cd into this repo)
#        - sources the saved credentials file via absolute path
#        - sources `<canonical>/.env.local` (if present) for repo-local overrides
#          (e.g., GLOO_BASE_URL=http://localhost:8000 when paired with /gloo-local-dev)
#        - warns if credentials are older than the configured TTL
#        - launches `bun run --conditions=browser <canonical>/packages/opencode/src/index.ts "$@"`
#      so opencode treats *your project* as the workspace while still finding
#      the Gloo AI provider seed and OAuth creds.
#
# Idempotent: re-running this script replaces the managed block; it doesn't
# touch any unmanaged definitions you may have written by hand.
#
# Usage:
#   ./install.sh                           # full install: preflight → symlink → auth (if needed) → rc
#   ./install.sh --auth                    # only run the credential prompt; rotate creds
#   ./install.sh --skip-auth               # full install but skip the auth flow even if creds missing
#   ./install.sh --auth-ttl-days N         # hygiene warning TTL in days (default 90)
#   ./install.sh --name oc                 # name the function "oc" instead of "gloocode"
#   ./install.sh --rc ~/.zprofile          # write into a non-default rc file
#   ./install.sh --canonical-path /path    # custom symlink location
#   ./install.sh --no-canonical            # skip symlink, hard-code clone path
#   ./install.sh --skip-install            # don't run `bun install`
#   ./install.sh --print                   # print the function block to stdout; no rc write
#   ./install.sh --uninstall               # remove the managed block + symlink (keeps creds file)
#   ./install.sh --uninstall-creds         # remove the credentials file too
#   ./install.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$SCRIPT_DIR"

NAME="gloocode"
RC_FILE=""
PRINT_ONLY=0
SKIP_INSTALL=0
UNINSTALL=0
UNINSTALL_CREDS=0
USE_CANONICAL=1
CANONICAL_DIR_OVERRIDE=""
AUTH_ONLY=0
SKIP_AUTH=0
AUTH_TTL_DAYS=90
GLOO_AUTH_URL="https://studio.ai.gloo.com/api-credentials"
GLOO_DEFAULT_BASE_URL="https://platform.ai.gloo.com"

usage() {
  sed -n '2,53p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)            NAME="${2:?missing value for --name}"; shift 2 ;;
    --rc)              RC_FILE="${2:?missing value for --rc}"; shift 2 ;;
    --canonical-path)  CANONICAL_DIR_OVERRIDE="${2:?missing value for --canonical-path}"; USE_CANONICAL=1; shift 2 ;;
    --no-canonical)    USE_CANONICAL=0; shift ;;
    --print)           PRINT_ONLY=1; shift ;;
    --skip-install)    SKIP_INSTALL=1; shift ;;
    --auth)            AUTH_ONLY=1; shift ;;
    --skip-auth)       SKIP_AUTH=1; shift ;;
    --auth-ttl-days)   AUTH_TTL_DAYS="${2:?missing value for --auth-ttl-days}"; shift 2 ;;
    --uninstall)       UNINSTALL=1; shift ;;
    --uninstall-creds) UNINSTALL_CREDS=1; UNINSTALL=1; shift ;;
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

# ---- Resolve credentials path ------------------------------------------

CREDS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/${NAME}"
CREDS_FILE="$CREDS_DIR/credentials"

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
# `${NAME}`, `${FUNCTION_PATH}`, and `${CREDS_FILE}` expand at install time.
# `\$HOME`, `\$@`, `\$_gloocode_*`, and other shell vars stay literal so they
# evaluate when the function is called.

read -r -d '' BLOCK <<EOF || true
$MARKER_BEGIN
# Launch the OpenCode TUI from your current cwd with the Gloo AI provider
# available. Stays in your invocation directory (so opencode treats that as
# the workspace) while sourcing creds from the user-level credentials store
# and the dev entry from a stable handle pointing at: $FUNCTION_PATH
${NAME}() {
  local _gloocode_repo="$FUNCTION_PATH"
  local _gloocode_creds="$CREDS_FILE"
  if [ ! -d "\$_gloocode_repo" ]; then
    echo "error: \$_gloocode_repo missing — re-run \$_gloocode_repo/install.sh from your clone" >&2
    return 1
  fi
  if [ ! -f "\$_gloocode_creds" ]; then
    echo "error: no Gloo credentials saved. Run: \$_gloocode_repo/install.sh --auth" >&2
    return 1
  fi
  (
    export PATH="\$HOME/.bun/bin:\$PATH"

    # Load saved credentials (canonical source — user-level, not per-clone).
    set -a; source "\$_gloocode_creds"; set +a

    # Soft TTL hygiene check. Gloo client_credentials don't expire on the
    # platform; this is a reminder to rotate periodically.
    if [ -n "\${GLOOCODE_CREDS_REFRESHED_EPOCH:-}" ] \\
       && [ -n "\${GLOOCODE_CREDS_TTL_DAYS:-}" ] \\
       && [ -z "\${GLOOCODE_SKIP_TTL_WARNING:-}" ]; then
      local _now_epoch _age_days
      _now_epoch=\$(date +%s)
      _age_days=\$(( (_now_epoch - GLOOCODE_CREDS_REFRESHED_EPOCH) / 86400 ))
      if [ "\$_age_days" -gt "\$GLOOCODE_CREDS_TTL_DAYS" ]; then
        echo "warning: Gloo credentials are \$_age_days days old (TTL: \$GLOOCODE_CREDS_TTL_DAYS). Rotate with: \$_gloocode_repo/install.sh --auth" >&2
      fi
    fi

    # Optional repo-local overrides (e.g., GLOO_BASE_URL=http://localhost:8000
    # when developing against a local ai-api stack).
    if [ -f "\$_gloocode_repo/.env.local" ]; then
      set -a; source "\$_gloocode_repo/.env.local"; set +a
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

open_url() {
  local url="$1"
  if command -v open >/dev/null 2>&1; then
    open "$url" 2>/dev/null && return 0
  fi
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" 2>/dev/null && return 0
  fi
  return 1
}

prompt_secret() {
  # Read a secret with no echo. Trailing newline emitted manually so the
  # prompt looks normal in a terminal.
  local prompt="$1" __dst_var="$2" __input
  if [ ! -t 0 ]; then
    echo "error: no TTY; cannot prompt for credentials interactively." >&2
    echo "       Run install.sh --auth from a terminal, or set creds in $CREDS_FILE." >&2
    return 1
  fi
  printf '%s' "$prompt" >&2
  read -r -s __input
  printf '\n' >&2
  printf -v "$__dst_var" '%s' "$__input"
}

mask_secret() {
  # Echo a secret with everything but the first 4 chars masked. For status
  # messages only — never log the raw value.
  local s="$1"
  local len=${#s}
  if [ "$len" -le 4 ]; then
    printf '••••'
  else
    printf '%s%s' "${s:0:4}" "$(printf '•%.0s' $(seq 1 $((len - 4))))"
  fi
}

validate_creds() {
  # Live OAuth2 client_credentials grant. Returns 0 on success; prints a
  # one-line diagnostic on failure.
  local cid="$1" csec="$2" base="${3:-$GLOO_DEFAULT_BASE_URL}"
  local resp body status
  if ! command -v curl >/dev/null 2>&1; then
    echo "  ! curl not found; skipping credential validation. Save anyway? (Y/n)" >&2
    local ans; read -r ans
    [[ "$ans" =~ ^[Nn] ]] && return 1
    return 0
  fi
  resp=$(curl -sS -X POST -u "${cid}:${csec}" \
    -d "grant_type=client_credentials" \
    -w '\n__HTTP_STATUS__:%{http_code}' \
    "${base%/}/oauth2/token" 2>&1) || true
  status=$(printf '%s' "$resp" | sed -n 's/^__HTTP_STATUS__://p' | tail -1)
  body=$(printf '%s' "$resp" | sed '/^__HTTP_STATUS__:/d')
  case "$status" in
    200)
      # Be tolerant about jq being absent; just look for access_token in body.
      if printf '%s' "$body" | grep -q '"access_token"'; then
        return 0
      fi
      echo "  ! 200 OK but no access_token in response body" >&2
      return 1
      ;;
    401|403)
      echo "  ! credentials rejected (HTTP $status). Double-check ID/secret." >&2
      return 1
      ;;
    *)
      echo "  ! credential validation failed (HTTP ${status:-no-response})." >&2
      [ -n "$body" ] && printf '    %s\n' "$body" | head -3 >&2
      return 1
      ;;
  esac
}

write_creds_file() {
  local cid="$1" csec="$2" base="$3" ttl="$4"
  local now_iso now_epoch
  now_epoch=$(date +%s)
  now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%S")

  mkdir -p "$CREDS_DIR"
  chmod 700 "$CREDS_DIR" 2>/dev/null || true

  # Write atomically: temp file, chmod, then rename. The shell-quote helper
  # below handles single-quote escaping for sourceable output.
  local tmp
  tmp="$(mktemp "${CREDS_FILE}.XXXXXX")"
  chmod 600 "$tmp"

  cat > "$tmp" <<CREDS_EOF
# Gloo AI credentials for the gloocode shell shortcut.
# Generated by ${REPO_ROOT}/install.sh — do not edit by hand.
# To rotate: ${REPO_ROOT}/install.sh --auth
GLOO_CLIENT_ID=$(printf '%q' "$cid")
GLOO_CLIENT_SECRET=$(printf '%q' "$csec")
GLOO_BASE_URL=$(printf '%q' "$base")
GLOOCODE_CREDS_REFRESHED_AT=$(printf '%q' "$now_iso")
GLOOCODE_CREDS_REFRESHED_EPOCH=$(printf '%q' "$now_epoch")
GLOOCODE_CREDS_TTL_DAYS=$(printf '%q' "$ttl")
CREDS_EOF

  mv "$tmp" "$CREDS_FILE"
  chmod 600 "$CREDS_FILE"
}

run_auth_flow() {
  echo "→ Auth"
  echo "  Opening Gloo Studio API credentials page in your browser…"
  echo "    $GLOO_AUTH_URL"
  if open_url "$GLOO_AUTH_URL"; then
    echo "  ✓ browser opened"
  else
    echo "  ! couldn't auto-open a browser. Please open the URL above manually." >&2
  fi
  echo
  echo "  Create or copy an OAuth client, then paste the values below."
  echo "  (Both fields are hidden — your input will not appear on screen.)"
  echo

  local CID CSEC
  prompt_secret "  GLOO_CLIENT_ID:     " CID || return 1
  if [ -z "$CID" ]; then
    echo "  ! empty client ID; aborting." >&2
    return 1
  fi
  prompt_secret "  GLOO_CLIENT_SECRET: " CSEC || return 1
  if [ -z "$CSEC" ]; then
    echo "  ! empty client secret; aborting." >&2
    return 1
  fi

  local BASE_URL="$GLOO_DEFAULT_BASE_URL"
  echo "  client_id=$(mask_secret "$CID")  secret_len=${#CSEC}  base_url=$BASE_URL"
  echo "  → validating against $BASE_URL/oauth2/token …"
  if ! validate_creds "$CID" "$CSEC" "$BASE_URL"; then
    return 1
  fi
  echo "  ✓ credentials validated"

  write_creds_file "$CID" "$CSEC" "$BASE_URL" "$AUTH_TTL_DAYS"
  echo "  ✓ saved to $CREDS_FILE (mode 0600, TTL ${AUTH_TTL_DAYS}d)"
}

creds_present() {
  [[ -f "$CREDS_FILE" ]] || return 1
  # Cheap, no-source check: just look for the env-var lines.
  grep -q '^GLOO_CLIENT_ID='     "$CREDS_FILE" || return 1
  grep -q '^GLOO_CLIENT_SECRET=' "$CREDS_FILE" || return 1
  return 0
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
  if [[ "$UNINSTALL_CREDS" -eq 1 ]]; then
    if [[ -f "$CREDS_FILE" ]]; then
      rm -f "$CREDS_FILE"
      echo "  ✓ removed credentials file $CREDS_FILE"
    fi
    if [[ -d "$CREDS_DIR" ]] && [[ -z "$(ls -A "$CREDS_DIR" 2>/dev/null)" ]]; then
      rmdir "$CREDS_DIR"
    fi
  else
    if [[ -f "$CREDS_FILE" ]]; then
      echo "  · keeping credentials file $CREDS_FILE (use --uninstall-creds to remove)"
    fi
  fi
  echo
  echo "Done. Open a new shell to drop the function from your environment."
  exit 0
fi

# ---- --auth short-circuit ----------------------------------------------

if [[ "$AUTH_ONLY" -eq 1 ]]; then
  if ! run_auth_flow; then
    exit 1
  fi
  echo
  echo "Done. Test with: ${NAME}"
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

  if [[ -e "$CANONICAL_DIR" && ! -L "$CANONICAL_DIR" ]]; then
    echo "  ! $CANONICAL_DIR exists and is not a symlink — refusing to overwrite." >&2
    echo "    Either move it aside or pass --canonical-path with a different location, or use --no-canonical." >&2
    exit 1
  fi

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

# ---- Auth ---------------------------------------------------------------

if creds_present; then
  echo "→ Auth"
  echo "  ✓ credentials already present at $CREDS_FILE"
  echo "    (rotate with: $REPO_ROOT/install.sh --auth)"
elif [[ "$SKIP_AUTH" -eq 1 ]]; then
  echo "→ Auth"
  echo "  · skipped (--skip-auth). Run \`$REPO_ROOT/install.sh --auth\` later before invoking ${NAME}."
else
  if [ -t 0 ]; then
    if ! run_auth_flow; then
      echo "  ! auth flow failed; aborting install." >&2
      echo "    You can retry: $REPO_ROOT/install.sh --auth" >&2
      exit 1
    fi
  else
    echo "→ Auth"
    echo "  · no TTY; skipping interactive auth. Run \`$REPO_ROOT/install.sh --auth\` from a terminal." >&2
  fi
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

To rotate credentials later: $REPO_ROOT/install.sh --auth
To remove:                   $REPO_ROOT/install.sh --uninstall
DONE
