---
name: gloo-env
description: Toggle Gloo AI provider between prod (platform.ai.gloo.com) and local (localhost:8000) in .env.local
argument-hint: '[prod|local]'
---

# Gloo Environment Toggle

Switch the Gloo AI provider base URL between production and local ai-api.

## Arguments

<arguments> #$ARGUMENTS </arguments>

**Parse arguments:**

- `prod` — set `GLOO_BASE_URL=https://platform.ai.gloo.com`
- `local` — set `GLOO_BASE_URL=http://localhost:8000`
- No argument — show the current setting

## Environments

| Name | `GLOO_BASE_URL` | Auth | API base |
|------|-----------------|------|----------|
| **prod** | `https://platform.ai.gloo.com` | OAuth2 token exchange (`/oauth2/token`) | `/ai/v2` |
| **local** | `http://localhost:8000` | No OAuth2 — any Bearer token accepted | `/ai/v2` |

### Auth difference (critical)

- **prod**: The opencode provider does a full OAuth2 client credentials exchange against `${GLOO_BASE_URL}/oauth2/token` to get a JWT, then uses it as Bearer token.
- **local**: The local ai-api has **no OAuth2 endpoint**. It runs with `ENVIRONMENT=local` which makes its auth module accept any non-empty Bearer token string (see `app/core/auth.py` line ~207). The opencode provider detects localhost and skips the token exchange, passing `GLOO_CLIENT_ID` directly as the Bearer token.

## Execution

### Step 1 — Read current state

Read the `.env.local` file at the project root (`/Users/patrick/src/glooai/opencode/.env.local`).

Look for a `GLOO_BASE_URL=...` line. If missing, the default is `http://localhost:8000` (local).

Report the current environment:
- If `GLOO_BASE_URL` contains `platform.ai.gloo.com` → **prod**
- If `GLOO_BASE_URL` contains `localhost` or is missing → **local**

If no argument was provided, stop here and just report the current state.

### Step 2 — Update .env.local

Use the Edit tool to update or add the `GLOO_BASE_URL` line in `.env.local`:

- If `GLOO_BASE_URL` already exists, replace the line.
- If it doesn't exist, add it after the other `GLOO_` vars.

Values:
- `prod` → `GLOO_BASE_URL=https://platform.ai.gloo.com`
- `local` → `GLOO_BASE_URL=http://localhost:8000`

### Step 3 — Confirm

After updating, read back the file to confirm the change, then tell the user:

- Which environment is now active
- Remind them to restart `bun run dev` for the change to take effect
- If switching to **local**, remind them that `~/src/TangoGroup/ai-api` must be running on port 8000 with `ENVIRONMENT=local` in its `.env`
- If switching to **local**, note that OAuth2 token exchange is skipped — the provider passes `GLOO_CLIENT_ID` directly as the Bearer token since the local ai-api accepts any token in local mode
- If switching to **prod**, note that real OAuth2 credentials are required — `GLOO_CLIENT_ID` and `GLOO_CLIENT_SECRET` must be valid Gloo platform credentials
