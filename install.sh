#!/usr/bin/env bash
#
# install.sh — Bootstrap a `gloocode` launcher from a local clone of
# glooai/opencode. Works regardless of where you cloned the repo and
# regardless of which shell you use.
#
# Architecture:
#
#   ${XDG_DATA_HOME:-~/.local/share}/gloocode  →  /your/clone/path     (symlink: stable handle for the repo)
#   ${XDG_CONFIG_HOME:-~/.config}/gloocode/credentials                 (mode 0600, sourceable shell file: GLOO_*)
#   ${BIN_DIR:-~/.local/bin}/gloocode                                  (mode 0755 executable shim — the canonical launcher)
#
#   Shell rc (~/.zshrc, ~/.bashrc, ~/.config/fish/conf.d/gloocode.fish)
#     — managed PATH-only block that ensures the shim's bin dir is on PATH.
#     — no shell function. The shim is a real executable; any shell can run it.
#
# What it does on a full install:
#
#   1. Preflight: verifies bun is on PATH (warns if version < 1.3.13). Runs
#      `bun install` if `node_modules` is absent (skip with --skip-install).
#
#   2. Stable handle: symlinks `${XDG_DATA_HOME:-~/.local/share}/gloocode`
#      to this clone, so the shim references a path that is stable across
#      machines and re-clones. Move the repo? Re-run install.sh from the new
#      location to update the symlink.
#
#   3. Auth (interactive): if no credentials are saved, opens
#      https://studio.ai.gloo.com/api-credentials in your browser, prompts
#      you to paste the client ID and secret separately (both hidden, no
#      shell-history leak). Validates them with a live OAuth2
#      client_credentials grant — the auth header is built the same way the
#      runtime provider builds it (encodeURIComponent on each field, then
#      base64), so credentials with reserved characters like `:` or `+` are
#      handled correctly. Persists to a 0600-mode file.
#
#   4. Shim install: writes an executable `gloocode` script at the bin dir.
#      The shim sources the credentials file as canonical, refuses to run
#      against `http://localhost*` unless `GLOOCODE_LOCAL=1` is set (matches
#      the verify-gloo.ts guard), and only sources `<repo>/.env.local` when
#      `GLOOCODE_LOCAL=1` is set — so a stale repo-local override cannot
#      silently break production launches.
#
#   5. Shell integration (PATH-only): ensures the bin dir is on PATH in your
#      shell rc. Per-shell rendering for zsh/bash/fish; unsupported shells
#      fail fast with manual instructions instead of silently writing to a
#      file you don't actually load.
#
# Idempotent at every layer. Re-running this script:
#   - replaces the managed rc block in place (no duplicates)
#   - rewrites the shim atomically (mktemp + chmod + rename)
#   - updates the canonical symlink target to point at the current clone
#
# Usage:
#   ./install.sh                           # full install
#   ./install.sh --auth                    # only run the credential prompt; rotate creds
#   ./install.sh --skip-auth               # full install but skip auth even if creds missing
#   ./install.sh --auth-ttl-days N         # hygiene warning TTL (default 90)
#   ./install.sh --name oc                 # use a different launcher name
#   ./install.sh --bin-dir /usr/local/bin  # custom shim location (default: ~/.local/bin)
#   ./install.sh --rc <path>               # explicit rc file (default: detect from $SHELL)
#   ./install.sh --canonical-path <path>   # custom symlink location
#   ./install.sh --no-canonical            # skip symlink, hard-code clone path
#   ./install.sh --skip-install            # don't run `bun install`
#   ./install.sh --print                   # print the shim + rc block to stdout; no writes
#   ./install.sh --uninstall               # remove shim, rc block, symlink (keeps creds)
#   ./install.sh --uninstall-creds         # also remove the credentials file
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
BIN_DIR_OVERRIDE=""
AUTH_ONLY=0
SKIP_AUTH=0
AUTH_TTL_DAYS=90
GLOO_AUTH_URL="https://studio.ai.gloo.com/api-credentials"
GLOO_DEFAULT_BASE_URL="https://platform.ai.gloo.com"

usage() {
  sed -n '2,79p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)            NAME="${2:?missing value for --name}"; shift 2 ;;
    --rc)              RC_FILE="${2:?missing value for --rc}"; shift 2 ;;
    --canonical-path)  CANONICAL_DIR_OVERRIDE="${2:?missing value for --canonical-path}"; USE_CANONICAL=1; shift 2 ;;
    --no-canonical)    USE_CANONICAL=0; shift ;;
    --bin-dir)         BIN_DIR_OVERRIDE="${2:?missing value for --bin-dir}"; shift 2 ;;
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

# ---- Resolve paths ------------------------------------------------------

DEFAULT_CANONICAL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/${NAME}"
CANONICAL_DIR="${CANONICAL_DIR_OVERRIDE:-$DEFAULT_CANONICAL_DIR}"

if [[ "$USE_CANONICAL" -eq 1 ]]; then
  HANDLE_PATH="$CANONICAL_DIR"
else
  HANDLE_PATH="$REPO_ROOT"
fi

CREDS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/${NAME}"
CREDS_FILE="$CREDS_DIR/credentials"

BIN_DIR="${BIN_DIR_OVERRIDE:-$HOME/.local/bin}"
SHIM_FILE="$BIN_DIR/${NAME}"

# ---- Detect shell + rc strategy -----------------------------------------
# SHELL_KIND: zsh | bash | fish | unknown
# RC_FILE:    (for zsh/bash) the rc file to mutate
#             (for fish)     the conf.d snippet path
#             (for unknown)  empty; rc step will fail fast

SHELL_KIND="unknown"
case "$(basename "${SHELL:-}")" in
  zsh)
    SHELL_KIND="zsh"
    [[ -z "$RC_FILE" ]] && RC_FILE="$HOME/.zshrc"
    ;;
  bash)
    SHELL_KIND="bash"
    if [[ -z "$RC_FILE" ]]; then
      # macOS Terminal launches login shells; bash reads .bash_profile then.
      if [[ -f "$HOME/.bash_profile" && ! -f "$HOME/.bashrc" ]]; then
        RC_FILE="$HOME/.bash_profile"
      else
        RC_FILE="$HOME/.bashrc"
      fi
    fi
    ;;
  fish)
    SHELL_KIND="fish"
    [[ -z "$RC_FILE" ]] && RC_FILE="$HOME/.config/fish/conf.d/${NAME}.fish"
    ;;
  *)
    SHELL_KIND="unknown"
    ;;
esac

MARKER_BEGIN="# >>> ${NAME} (managed by glooai/opencode install.sh) >>>"
MARKER_END="# <<< ${NAME} <<<"

# ---- Compose the rc block (PATH-only) ----------------------------------
# Per shell. Always idempotent.

render_rc_block() {
  local kind="$1" bin="$2"
  case "$kind" in
    zsh|bash)
      cat <<EOF
$MARKER_BEGIN
# Ensure the ${NAME} shim is on PATH.
case ":\$PATH:" in
  *":${bin}:"*) ;;
  *) export PATH="${bin}:\$PATH" ;;
esac
$MARKER_END
EOF
      ;;
    fish)
      cat <<EOF
$MARKER_BEGIN
# Ensure the ${NAME} shim is on PATH.
fish_add_path -p -g ${bin}
$MARKER_END
EOF
      ;;
    *)
      return 1
      ;;
  esac
}

# ---- Compose the shim ---------------------------------------------------
# `${HANDLE_PATH}` and `${CREDS_FILE}` and `${REPO_ROOT}` expand at install time.
# Other `\$...` references stay literal — they evaluate when the shim runs.

render_shim() {
  cat <<EOF
#!/usr/bin/env bash
#
# ${NAME} — auto-generated by glooai/opencode install.sh.
# Do not edit by hand; this file is rewritten on every \`install.sh\` run.
# To regenerate: $REPO_ROOT/install.sh
# To rotate creds: $REPO_ROOT/install.sh --auth

set -eu

GLOOCODE_REPO="\${GLOOCODE_REPO_OVERRIDE:-${HANDLE_PATH}}"
GLOOCODE_CREDS="\${GLOOCODE_CREDS_OVERRIDE:-${CREDS_FILE}}"
GLOOCODE_REINSTALL_HINT="${REPO_ROOT}/install.sh"

if [ ! -d "\$GLOOCODE_REPO" ]; then
  echo "error: \$GLOOCODE_REPO missing — re-run \$GLOOCODE_REINSTALL_HINT from your clone" >&2
  exit 1
fi
if [ ! -f "\$GLOOCODE_CREDS" ]; then
  echo "error: no Gloo credentials saved. Run: \$GLOOCODE_REINSTALL_HINT --auth" >&2
  exit 1
fi

# Bun (the canonical install location) — best-effort PATH augmentation.
case ":\$PATH:" in
  *":\$HOME/.bun/bin:"*) ;;
  *) export PATH="\$HOME/.bun/bin:\$PATH" ;;
esac

# Source credentials FIRST as the canonical source of GLOO_*.
# (.env.local is handled below, only when GLOOCODE_LOCAL=1.)
set -a
# shellcheck disable=SC1090
. "\$GLOOCODE_CREDS"
set +a

# Soft TTL hygiene check. Gloo client_credentials don't expire on the
# platform; this is a reminder to rotate periodically. Suppress with
# GLOOCODE_SKIP_TTL_WARNING=1.
if [ -n "\${GLOOCODE_CREDS_REFRESHED_EPOCH:-}" ] \\
   && [ -n "\${GLOOCODE_CREDS_TTL_DAYS:-}" ] \\
   && [ -z "\${GLOOCODE_SKIP_TTL_WARNING:-}" ]; then
  age_days=\$(( (\$(date +%s) - GLOOCODE_CREDS_REFRESHED_EPOCH) / 86400 ))
  if [ "\$age_days" -gt "\$GLOOCODE_CREDS_TTL_DAYS" ]; then
    printf 'warning: Gloo credentials are %s days old (TTL: %s). Rotate with: %s --auth\\n' \\
      "\$age_days" "\$GLOOCODE_CREDS_TTL_DAYS" "\$GLOOCODE_REINSTALL_HINT" >&2
  fi
fi

# Local-dev opt-in. .env.local is only sourced when GLOOCODE_LOCAL=1, so a
# stale repo-local override cannot silently send production launches at
# localhost. (This mirrors the verify-gloo.ts --local guard.)
if [ "\${GLOOCODE_LOCAL:-0}" = "1" ]; then
  if [ -f "\$GLOOCODE_REPO/.env.local" ]; then
    set -a
    # shellcheck disable=SC1090
    . "\$GLOOCODE_REPO/.env.local"
    set +a
  fi
fi

# Validate GLOO_BASE_URL — refuse localhost without explicit opt-in.
case "\${GLOO_BASE_URL:-}" in
  https://*) ;;
  http://localhost*|http://127.0.0.1*|http://0.0.0.0*)
    if [ "\${GLOOCODE_LOCAL:-0}" != "1" ]; then
      printf 'error: GLOO_BASE_URL=%s but GLOOCODE_LOCAL=1 not set.\\n' "\$GLOO_BASE_URL" >&2
      printf '  For local-dev mode against ai-api: GLOOCODE_LOCAL=1 %s\\n' "${NAME}" >&2
      printf '  To restore prod default in your creds: %s --auth\\n' "\$GLOOCODE_REINSTALL_HINT" >&2
      exit 1
    fi
    ;;
  '')
    echo "error: GLOO_BASE_URL is empty. Re-run: \$GLOOCODE_REINSTALL_HINT --auth" >&2
    exit 1
    ;;
  *)
    printf 'error: invalid GLOO_BASE_URL=%s (expected https:// or http://localhost)\\n' "\$GLOO_BASE_URL" >&2
    exit 1
    ;;
esac

# Launch via the gloocode-launch wrapper:
#   - bun runs from packages/opencode so it finds tsconfig.json (JSX +
#     @opentui/solid jsxImportSource);
#   - the wrapper then chdir's to the original invocation cwd so opencode's
#     process.cwd() at runtime is the user's project, not opencode source.
ORIG_CWD="\$(pwd)"
exec env GLOOCODE_ORIG_CWD="\$ORIG_CWD" \\
  bun run \\
    --cwd "\$GLOOCODE_REPO/packages/opencode" \\
    --conditions=browser \\
    ./script/gloocode-launch.ts \\
    "\$@"
EOF
}

# ---- --print short-circuit ---------------------------------------------

if [[ "$PRINT_ONLY" -eq 1 ]]; then
  echo "==== shim ($SHIM_FILE) ===="
  render_shim
  echo
  echo "==== rc block ($SHELL_KIND → $RC_FILE) ===="
  if [[ "$SHELL_KIND" == "unknown" ]]; then
    echo "(no managed rc block — your shell is not auto-supported; add this directory to PATH manually:)"
    echo "  $BIN_DIR"
  else
    render_rc_block "$SHELL_KIND" "$BIN_DIR"
  fi
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

remove_shim() {
  if [[ -f "$SHIM_FILE" ]] && head -1 "$SHIM_FILE" 2>/dev/null | grep -q '^#!/usr/bin/env bash$' \
     && grep -q "^# ${NAME} — auto-generated by glooai/opencode install.sh" "$SHIM_FILE" 2>/dev/null; then
    rm "$SHIM_FILE"
    echo "  ✓ removed shim $SHIM_FILE"
  elif [[ -e "$SHIM_FILE" ]]; then
    echo "  ! $SHIM_FILE exists but is not a managed gloocode shim — leaving it untouched" >&2
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
  local s="$1"
  local len=${#s}
  if [ "$len" -le 4 ]; then
    printf '••••'
  else
    printf '%s%s' "${s:0:4}" "$(printf '•%.0s' $(seq 1 $((len - 4))))"
  fi
}

percent_encode() {
  # Matches JS encodeURIComponent: percent-encodes everything except
  # A-Z a-z 0-9 - _ . ~ ! * ' ( ).  Provider.ts and verify-gloo.ts both use
  # encodeURIComponent on client_id and client_secret before base64ing for
  # the OAuth Basic header — install.sh now matches.
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c '
import sys, urllib.parse
sys.stdout.write(urllib.parse.quote(sys.stdin.read(), safe="!*\x27()"))
'
  else
    # Bash fallback. Sufficient for ASCII OAuth client_ids/secrets, which is
    # what Gloo issues.
    local s="$1" out=""
    local i c
    for ((i=0; i<${#s}; i++)); do
      c="${s:$i:1}"
      case "$c" in
        [a-zA-Z0-9._~!*\(\)\'-]) out+="$c" ;;
        *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
      esac
    done
    printf '%s' "$out"
  fi
}

basic_auth_header() {
  # Build the OAuth2 Basic auth header explicitly the same way the runtime
  # provider does: percent-encode each field with encodeURIComponent
  # semantics, concatenate with `:`, base64 the bytes, prefix with "Basic ".
  local cid="$1" csec="$2"
  local cid_enc csec_enc encoded
  cid_enc=$(percent_encode "$cid")
  csec_enc=$(percent_encode "$csec")
  encoded=$(printf '%s:%s' "$cid_enc" "$csec_enc" | base64 | tr -d '\n')
  printf 'Basic %s' "$encoded"
}

validate_creds() {
  # Live OAuth2 client_credentials grant, using the same auth-header
  # construction as the runtime provider so credentials with reserved
  # characters round-trip correctly.
  local cid="$1" csec="$2" base="${3:-$GLOO_DEFAULT_BASE_URL}"
  local resp body status auth
  if ! command -v curl >/dev/null 2>&1; then
    echo "  ! curl not found; skipping credential validation. Save anyway? (Y/n)" >&2
    local ans; read -r ans
    [[ "$ans" =~ ^[Nn] ]] && return 1
    return 0
  fi
  auth=$(basic_auth_header "$cid" "$csec")
  resp=$(curl -sS -X POST \
    -H "Authorization: $auth" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "scope=api/access" \
    -w '\n__HTTP_STATUS__:%{http_code}' \
    "${base%/}/oauth2/token" 2>&1) || true
  status=$(printf '%s' "$resp" | sed -n 's/^__HTTP_STATUS__://p' | tail -1)
  body=$(printf '%s' "$resp" | sed '/^__HTTP_STATUS__:/d')
  case "$status" in
    200)
      if printf '%s' "$body" | grep -q '"access_token"'; then
        return 0
      fi
      echo "  ! 200 OK but no access_token in response body" >&2
      return 1
      ;;
    400|401|403)
      echo "  ! credentials rejected (HTTP $status)." >&2
      [ -n "$body" ] && printf '    %s\n' "$body" | head -3 >&2
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

  local tmp
  tmp="$(mktemp "${CREDS_FILE}.XXXXXX")"
  chmod 600 "$tmp"

  cat > "$tmp" <<CREDS_EOF
# Gloo AI credentials for the ${NAME} launcher.
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
  grep -q '^GLOO_CLIENT_ID='     "$CREDS_FILE" || return 1
  grep -q '^GLOO_CLIENT_SECRET=' "$CREDS_FILE" || return 1
  return 0
}

# ---- --uninstall short-circuit -----------------------------------------

if [[ "$UNINSTALL" -eq 1 ]]; then
  echo "→ Uninstall"
  if [[ -n "$RC_FILE" && -f "$RC_FILE" ]] && grep -qF "$MARKER_BEGIN" "$RC_FILE"; then
    strip_managed_block "$RC_FILE"
    echo "  ✓ removed ${NAME} block from $RC_FILE"
  else
    echo "  · no managed ${NAME} block in ${RC_FILE:-(no rc file detected)}"
  fi
  remove_shim
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
  echo "Done. Open a new shell to drop ${BIN_DIR} from PATH."
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
  echo "    The shim adds \$HOME/.bun/bin to PATH automatically once bun is installed."
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
    echo "    Either move it aside or pass --canonical-path, or use --no-canonical." >&2
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
  echo "  · skipped (--no-canonical); shim will reference $REPO_ROOT directly"
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

# ---- Install shim -------------------------------------------------------

echo "→ Shim"
mkdir -p "$BIN_DIR"

# Refuse to clobber a non-managed file at the shim path.
if [[ -e "$SHIM_FILE" && ! -f "$SHIM_FILE" ]]; then
  echo "  ! $SHIM_FILE exists and is not a regular file — refusing to overwrite." >&2
  exit 1
fi
if [[ -f "$SHIM_FILE" ]] && ! grep -q "^# ${NAME} — auto-generated by glooai/opencode install.sh" "$SHIM_FILE" 2>/dev/null; then
  echo "  ! $SHIM_FILE exists and is not a managed ${NAME} shim — refusing to overwrite." >&2
  echo "    Move it aside or pass --bin-dir <path> with a different location." >&2
  exit 1
fi

# Atomic write: temp file, chmod, rename.
SHIM_TMP="$(mktemp "${SHIM_FILE}.XXXXXX")"
render_shim > "$SHIM_TMP"
chmod 755 "$SHIM_TMP"
mv "$SHIM_TMP" "$SHIM_FILE"
echo "  ✓ wrote shim to $SHIM_FILE (mode 0755)"

# Sanity: bash should be able to parse the shim.
if bash -n "$SHIM_FILE" 2>/dev/null; then
  echo "  ✓ shim syntax OK"
else
  echo "  ! shim syntax check failed; please review $SHIM_FILE" >&2
fi

# ---- Shell integration --------------------------------------------------

echo "→ Shell integration"

if [[ "$SHELL_KIND" == "unknown" ]]; then
  cat <<UNSUPPORTED
  ! Detected shell: $(basename "${SHELL:-unknown}")
    No managed rc block written. Add the bin dir to PATH manually in your
    shell's startup file:

      $BIN_DIR

    Then run: ${NAME}

    (Or pass --rc <path> to write the bash/zsh-style PATH snippet to a
     file you do source.)
UNSUPPORTED
else
  mkdir -p "$(dirname "$RC_FILE")"
  [[ -f "$RC_FILE" ]] || touch "$RC_FILE"

  strip_managed_block "$RC_FILE"

  # After strip, any remaining ${NAME} function or alias is unmanaged by
  # construction. In zsh/bash, shell functions take precedence over PATH-
  # resolved binaries, so an unmanaged function will *shadow* the shim
  # silently. Detect and warn loudly.
  if [[ "$SHELL_KIND" == "zsh" || "$SHELL_KIND" == "bash" ]]; then
    if grep -Eq "^[[:space:]]*${NAME}[[:space:]]*\(\)|^[[:space:]]*function[[:space:]]+${NAME}[[:space:]]*\(?\)?[[:space:]]*\{|^[[:space:]]*alias[[:space:]]+${NAME}=" "$RC_FILE"; then
      echo "  ! Detected an unmanaged '${NAME}' function or alias in $RC_FILE." >&2
      echo "    Shell functions take precedence over PATH-resolved binaries, so this" >&2
      echo "    will SHADOW the new shim at ${SHIM_FILE} when you type \`${NAME}\`." >&2
      echo "    Remove the function/alias by hand to let the shim take over." >&2
    fi
  fi

  {
    if [[ -s "$RC_FILE" ]] && [[ -n "$(tail -c1 "$RC_FILE" 2>/dev/null || true)" ]]; then
      printf '\n'
    fi
    printf '\n'
    render_rc_block "$SHELL_KIND" "$BIN_DIR"
  } >> "$RC_FILE"

  echo "  ✓ wrote managed PATH block to $RC_FILE ($SHELL_KIND)"

  case "$SHELL_KIND" in
    zsh)  zsh -n "$RC_FILE" 2>/dev/null && echo "  ✓ rc syntax OK" || echo "  ! syntax check failed; please review $RC_FILE" >&2 ;;
    bash) bash -n "$RC_FILE" 2>/dev/null && echo "  ✓ rc syntax OK" || echo "  ! syntax check failed; please review $RC_FILE" >&2 ;;
    fish) command -v fish >/dev/null 2>&1 && fish -n "$RC_FILE" 2>/dev/null && echo "  ✓ rc syntax OK" \
            || echo "  · skipped fish syntax check (no fish on PATH)" ;;
  esac
fi

# Inform the user about PATH state in *this* shell.
case ":$PATH:" in
  *":$BIN_DIR:"*)
    echo "  ✓ $BIN_DIR is already on PATH in this shell"
    ;;
  *)
    echo "  ! $BIN_DIR is not yet on PATH in this shell — open a new terminal or \`source\` your rc"
    ;;
esac

cat <<DONE

Done. To use ${NAME} now in this shell:

  source $RC_FILE      # zsh/bash; for fish: \`source ${RC_FILE}\` or new shell
  ${NAME}

Or open a new terminal. From any directory, just run \`${NAME}\` to launch the
OpenCode TUI with your project's cwd as the workspace and the Gloo AI provider
available in the model picker.

Local-dev mode (against a local TangoGroup/ai-api stack):
  GLOOCODE_LOCAL=1 ${NAME}      # opt-in, sources <repo>/.env.local

To rotate credentials:  $REPO_ROOT/install.sh --auth
To remove:              $REPO_ROOT/install.sh --uninstall
DONE
