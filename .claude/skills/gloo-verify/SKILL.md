---
name: gloo-verify
description: End-to-end smoke verification of OpenCode's Gloo AI provider — branch sanity, creds, static catalog, OAuth2, and live streaming/rejection checks against platform.ai.gloo.com (or local ai-api).
argument-hint: '[--local]'
---

# Gloo AI Provider Verifier

Runs `packages/opencode/script/verify-gloo.ts` and interprets the result. Use this any time you've touched provider code, rebased onto upstream, or want a 15-second sanity check that the integration still works end-to-end.

## Arguments

<arguments> #$ARGUMENTS </arguments>

**Parse arguments:**

- `--local` — point at `http://localhost:8000` (local ai-api) instead of production. Requires the ai-api stack to be running; pair with `/gloo-local-dev` first.
- No arguments — hits `https://platform.ai.gloo.com` (default).

## What gets verified

| Check | What it asserts |
|---|---|
| **Branch** | Current branch + short HEAD (so you know which build you're testing) |
| **Bun** | Bun runtime is available and current (pre-push hook needs ≥1.3.13) |
| **Creds** | `GLOO_CLIENT_ID` + `GLOO_CLIENT_SECRET` are present in env (masked echo) |
| **Catalog** | Reads `provider.ts`, asserts seed list has the right model count, the right `toolcall:false` flags, and that decommissioned models (e.g. `gemini-3-pro-preview`) are absent |
| **Token** | Live OAuth2 `client_credentials` grant against `platform.ai.gloo.com/oauth2/token` (skipped in local mode — local accepts any Bearer) |
| **Stream** | Live streaming requests against a representative subset (Sonnet 4.6 text+tools, GPT-4.1 with tools, DeepSeek R1 text) |
| **Reject** | Live request that *should* be 4xx-rejected (DeepSeek R1 with tools) — confirms the platform's "does not support function calling" contract is respected |

Companion to `packages/opencode/test/provider/gloo-models.test.ts` which covers the full 23-model matrix. The verifier deliberately runs a small set so it stays under 20 seconds.

## How to run

The skill orchestrates the following:

### 1. Source credentials

Credentials live in `.env.local` at the repo root (symlink to `../opencode.data/.env.local`). The harness needs them in the current shell environment, so:

```bash
set -a && source .env.local && set +a
```

If `.env.local` is missing, walk the user through the recovery: it should mirror `.env.example`, with `GLOO_CLIENT_ID` and `GLOO_CLIENT_SECRET` from the Gloo Studio OAuth client.

### 2. Ensure bun is on PATH

Pre-push hooks require bun ≥1.3.13. If the system bun is older, prefer `~/.bun/bin/bun`:

```bash
export PATH="$HOME/.bun/bin:$PATH"
bun --version    # should be 1.3.13+
```

### 3. Run the verifier

For production (default):

```bash
bun run --cwd packages/opencode verify:gloo
```

For local ai-api:

```bash
# only after /gloo-local-dev has confirmed ai-api is up on :8000
unset GLOO_BASE_URL    # or set to http://localhost:8000
bun run --cwd packages/opencode verify:gloo -- --local
```

### 4. Interpret the output

Each check prints a `✅` or `❌` with timing. The script exits 0 on full pass, 1 on any failure.

**On pass** — confirm "PASS  N/N checks green" and report success.

**On failure** — read the offending lines, classify, and surface a one-paragraph summary plus suggested next action:

| Failure pattern | Likely cause | Suggested next step |
|---|---|---|
| `Creds` red | `.env.local` not sourced or missing | Run `set -a && source .env.local && set +a` and retry |
| `Catalog` red | `provider.ts` seed drifted from expected | Compare `glooModelDefs` array against the verifier's expectations; either fix the seed or update the verifier's expectations if Gloo changed something |
| `Token` red, status 401 | Creds rotated or revoked | Check Gloo Studio for the OAuth client; rotate `.env.local` |
| `Stream` red on Anthropic | Platform-side regression | Tail recent canary logs (`#alerts-glooai`); file a bug report via `/gloo-bug-report` |
| `Stream` red on OpenAI with tools | Platform tool-streaming regression (the original headline bug) | This was fixed 2026-04-27 — if it's back, ping `@eliokazu` and `@jsouthern-ai` on PR #1 immediately |
| `Reject` red | Platform now accepts tools for a model we marked `toolcall:false` | Promote the model back to `toolcall: true` in `provider.ts` and rerun |

When reporting a failure, include the trace ID from the response if visible (verifier surfaces it in the `Reject` row; for `Stream` failures, encourage the user to dig into `~/.local/share/opencode/log/<latest>.log` and grep for `gloo`).

## Output expectation

Cleanly formatted, ~12 lines:

```
Gloo AI provider verifier · PRODUCTION

✅  Branch          feat/gloo-ai-provider @ <sha>
✅  Bun             1.3.13
✅  Creds           client_id=…  secret_len=…  baseUrl=https://platform.ai.gloo.com
✅  Catalog         22 models seeded; toolcall:false on 3 (deepseek-r1, llama-4-maverick, llama-3.1-8b-instruct)
✅  Token           OAuth2 client_credentials grant → …
✅  Stream          gloo-anthropic-claude-sonnet-4.6 (text )  → text ok
✅  Stream          gloo-anthropic-claude-sonnet-4.6 (tools)  → tool-call ok
✅  Stream          gloo-openai-gpt-4.1              (tools)  → tool-call ok
✅  Stream          gloo-deepseek-r1                 (text )  → text ok
✅  Reject          gloo-deepseek-r1                 (tools)  → 400 Model 'gloo-deepseek-r1' does not support function calling.

PASS  10/10 checks green
```

## When NOT to use this

- For the full 23-model matrix → use `bun run --cwd packages/opencode test test/provider/gloo-models.test.ts --timeout 300000` instead.
- For UX/picker validation → that's irreducibly human; spin up `bun run --cwd packages/opencode dev` and exercise the model picker by hand.

## Related Skills & Repos

- `/gloo-local-dev` — bring up the full local stack (ai-api + opencode env) before running this with `--local`
- `/gloo-env` — toggle `.env.local` between prod and local Gloo
- `/dev-logs` — tail OpenCode + ai-api logs while debugging a failed stream
