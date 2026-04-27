---
name: gloo-local-dev
description: Orchestrate local Gloo AI development — verify ai-api is running, configure opencode, and tail both log streams for troubleshooting
argument-hint: '[--skip-api] [--skip-opencode] [--no-logs]'
---

# Gloo Local Dev Orchestrator

Ensures the full local Gloo AI stack is ready: the ai-api backend on localhost:8000 and this opencode fork configured to use it. Always tails both log streams at the end for end-to-end visibility.

## Arguments

<arguments> #$ARGUMENTS </arguments>

**Parse arguments:**

- `--skip-api` — skip ai-api checks (assume it's already running)
- `--skip-opencode` — skip opencode env configuration
- `--no-logs` — skip log tailing at the end (just do setup)
- No arguments — full orchestration AND tail both log streams

---

## Related Skills & Repos

This skill coordinates two separate stacks that each have their own tooling:

| Stack | Repo | Claude Skill | Logs |
|-------|------|-------------|------|
| **ai-api** (backend) | `$AI_API_DIR` (set in `.env.local`) | `/local-dev-setup` in that repo | stderr via loguru (uvicorn terminal) |
| **opencode** (frontend) | this repo | `/dev-logs` in this repo | `~/.local/share/opencode/log/dev.log` |

The ai-api repo has its own Claude skill (`/local-dev-setup`) that handles Poetry install, PostgreSQL, Redis, migrations, and env setup. This orchestrator delegates to that skill's knowledge rather than duplicating it.

### Auth difference: local vs prod

**This is the most common source of confusion when testing locally.**

- **prod** (`platform.ai.gloo.com`): opencode does a full OAuth2 client credentials exchange at `/oauth2/token` to get a JWT, then sends it as `Bearer <jwt>` on every request.
- **local** (`localhost:8000`): The local ai-api has **no `/oauth2/token` endpoint** — it doesn't issue tokens. Instead, when `ENVIRONMENT=local` in its `.env`, the auth module (`app/core/auth.py`) accepts any non-empty Bearer token string. The opencode provider detects localhost and skips OAuth2, passing `GLOO_CLIENT_ID` directly as the Bearer token.

If you see `token request failed (404): {"detail":"Not Found"}`, it means opencode is trying to do an OAuth2 exchange against the local ai-api, which doesn't have that endpoint. Ensure `GLOO_BASE_URL` is set to `http://localhost:8000` (or unset, which defaults to localhost) so the provider skips OAuth2.

---

## Phase 1 — Locate ai-api

Read `AI_API_DIR` from `.env.local` in this repo's root:

```bash
grep '^AI_API_DIR=' .env.local | cut -d= -f2-
```

Store the result as `$AI_API_DIR`. Then verify the repo exists:

```bash
ls "$AI_API_DIR/app/main.py" 2>/dev/null
```

**If `AI_API_DIR` is not set in `.env.local`**, stop:

```
AI_API_DIR is not configured. Add it to .env.local:

  echo 'AI_API_DIR=/path/to/your/ai-api' >> .env.local

This should point to your local clone of TangoGroup/ai-api.
```

**If `AI_API_DIR` is set but the path doesn't exist**, stop:

```
AI_API_DIR is set to $AI_API_DIR but the repo wasn't found there.
Clone it: git clone git@github.com:TangoGroup/ai-api.git $AI_API_DIR
```

If `--skip-api` and `--skip-opencode`, skip to Phase 6.

---

## Phase 2 — Check ai-api prerequisites

**Skip if `--skip-api`.**

### 2a. Host tooling (Python, Poetry)

```bash
python3.11 --version   # must be 3.11+
poetry --version        # must be 2.x
ls $AI_API_DIR/.env     # must exist
```

### 2b. Dockerized services (PostgreSQL, Redis)

**Always use the docker-compose services** in the ai-api repo — never brew-managed postgres or redis. This keeps ports and data isolated per project.

```bash
# Check Docker containers
docker ps --filter "name=ai-api-postgres" --format "{{.Names}} {{.Status}}"
docker ps --filter "name=ai-api-redis" --format "{{.Names}} {{.Status}}"
```

If containers aren't running, start them:

```bash
cd $AI_API_DIR && docker compose up -d postgres redis-stack
```

Verify connectivity:

```bash
docker exec ai-api-postgres-1 pg_isready -U postgres -p 5438
docker exec ai-api-redis-stack-1 redis-cli ping
```

### 2c. Report status table

```
Prerequisite Check:
  Python 3.11+:           OK (3.11.15)
  Poetry 2.x:              OK (2.3.3)
  Docker postgres (5438):   OK (Up 2 minutes)
  Docker redis (6379):      OK (PONG)
  ai-api .env:              OK
```

For failures:

| Missing | Fix |
|---------|-----|
| Python 3.11 | `brew install python@3.11` |
| Poetry | `pipx install poetry && poetry self add poetry-plugin-shell` |
| Docker not running | `open -a Docker` or `brew install --cask docker` |
| Postgres/Redis containers down | `cd $AI_API_DIR && docker compose up -d postgres redis-stack` |
| `aiapi` database missing | `docker exec ai-api-postgres-1 psql -U postgres -p 5438 -c "CREATE DATABASE aiapi;"` |
| .env missing | `cp $AI_API_DIR/.env.example $AI_API_DIR/.env` — remind to set `ENVIRONMENT=local` |
| .env DB_URL pointing to port 5432 | Update to `postgresql://postgres:postgres@localhost:5438/aiapi` (dockerized port) |

Stop on any critical failure (Python, Poetry, Docker). Containers can be started automatically.

---

## Phase 3 — Check if ai-api is already running

**Skip if `--skip-api`.**

```bash
curl -sf -o /dev/null -w "%{http_code}" http://localhost:8000/docs 2>/dev/null
```

- `200` — already running. Log: "ai-api running on localhost:8000" and skip to Phase 5.
- Otherwise — continue to Phase 4.

---

## Phase 4 — Start ai-api automatically

**Skip if `--skip-api` or already running.**

Start the ai-api server automatically in the background. This avoids requiring the user to open a separate terminal.

### 4a. Run migrations

```bash
cd $AI_API_DIR && poetry run alembic upgrade head 2>&1 | tail -5
```

If migrations fail, stop and report the error. Common fix: the database may not exist yet — refer user to `/local-dev-setup` in the ai-api repo.

### 4b. Start uvicorn in background

Use the Bash tool with `run_in_background: true` to start the server. Redirect all output to `/tmp/ai-api-dev.log` for later tailing:

```bash
cd $AI_API_DIR && poetry run uvicorn app.main:app --reload --host 0.0.0.0 --port 8000 > /tmp/ai-api-dev.log 2>&1
```

### 4c. Wait and verify

Wait 5 seconds, then curl the health endpoint:

```bash
sleep 5 && curl -sf -o /dev/null -w "%{http_code}" http://localhost:8000/docs
```

- `200` — server is up. Log: "ai-api started successfully (background, logs at /tmp/ai-api-dev.log)"
- Otherwise — read the last 20 lines of `/tmp/ai-api-dev.log` and report the startup error. Common issues:
  - Port 8000 already in use → suggest `lsof -i :8000`
  - Missing env var (`ENVIRONMENT`) → remind to set it in `.env`
  - Database connection failure → check PostgreSQL is running

---

## Phase 5 — Configure opencode for local

**Skip if `--skip-opencode`.**

Read `.env.local` at the root of this repo.

**Check `GLOO_BASE_URL`:**
- Already `http://localhost:8000` — log "opencode already pointing to local" and skip.
- Different or missing — update it:
  - If `GLOO_BASE_URL=` line exists, replace the value with `http://localhost:8000`
  - If no `GLOO_BASE_URL` line, add `GLOO_BASE_URL=http://localhost:8000` after the other `GLOO_` vars

**Check credentials:**
- Verify both `GLOO_CLIENT_ID` and `GLOO_CLIENT_SECRET` are present and non-empty in `.env.local`.
- If missing, stop and tell the user to add them. These are the OAuth2 client credentials that ai-api validates.

---

## Phase 6 — Log tailing (always runs by default)

**Skip only if `--no-logs`.**

This phase reads both log streams simultaneously and presents a correlated summary. This is the default final step of every run — you always want visibility into what both stacks are doing.

### 6a. ai-api logs

The ai-api uses loguru which writes to stderr by default. There is no log file unless the user pipes to `tee`.

Check if `/tmp/ai-api-dev.log` exists:

```bash
ls -la /tmp/ai-api-dev.log 2>/dev/null
```

- **If exists**: Use it as the log source. Read the last 30 lines and search for errors.
- **If missing**: Tell the user to restart uvicorn with `tee`:
  ```
  uvicorn app.main:app --reload 2>&1 | tee /tmp/ai-api-dev.log
  ```
  Then skip ai-api log analysis (no file to read).

When reading ai-api logs, look for:

| Pattern | Meaning |
|---------|---------|
| `Uvicorn running on` | Server started successfully |
| `ERROR` or `Traceback` | Python exception — show the full traceback |
| `401` or `403` | Auth rejection — check token/credentials |
| `POST /ai/v2/chat/completions` | Incoming request from opencode |
| `status_code=500` | Server error — show surrounding context |
| `WARNING` with `deprecat` | Non-critical but worth noting |

### 6b. opencode logs

Use the same approach as the `/dev-logs` skill:

```bash
LOG_FILE="$HOME/.local/share/opencode/log/dev.log"
```

Read the last 30 lines and search for gloo-related entries. Look for the patterns documented in `/dev-logs`:
- `gloo provider init` — provider loaded
- `gloo token acquired` / `gloo token request failed` — auth flow
- `gloo fetch` — outbound request to ai-api
- `stream error` — streaming failure

### 6c. Correlate

After reading both log streams, correlate them:

1. **Request matching**: Find opencode `gloo fetch` entries and match them to ai-api `POST /ai/v2/chat/completions` entries by timestamp proximity.

2. **Error tracing**: If opencode shows a streaming error, check ai-api logs at the same timestamp for the server-side cause (traceback, timeout, model error).

3. **Auth flow**: If opencode shows `gloo token request failed`, check ai-api logs for the corresponding 401/403 and the reason.

Present findings as:

```
Log Analysis (last 30 lines each):

  opencode:  3 INFO, 0 WARN, 1 ERROR
  ai-api:    12 INFO, 1 WARNING, 0 ERROR

  Timeline:
    19:50:14  opencode → gloo fetch (POST /ai/v2/chat/completions)
    19:50:14  ai-api   ← received request, routing to anthropic-direct
    19:50:16  ai-api   → streaming response started
    19:50:16  opencode ← stream error after 1.2s

  Diagnosis: [summary of what went wrong and where]
```

---

## Phase 7 — Ready prompt

Once both stacks are confirmed ready:

```
Local Gloo AI stack is ready!

  ai-api:    http://localhost:8000 (running)
  opencode:  GLOO_BASE_URL=http://localhost:8000
  creds:     GLOO_CLIENT_ID present, GLOO_CLIENT_SECRET present

To test, open a new terminal tab in this repo and run:

  bun run dev

Then select a Gloo model (e.g. gloo-anthropic-claude-sonnet-4.6) and send a message.

Troubleshooting:
  /gloo-local-dev                  Re-run checks + tail both log streams
  /dev-logs gloo                   Tail opencode logs only (gloo entries)
  /gloo-env prod                   Switch back to production

ai-api setup issues? Open a Claude Code session in $AI_API_DIR
and run /local-dev-setup for guided repair.
```

---

## Error Handling

| Condition | Action |
|---|---|
| ai-api repo not found | Stop with clone instructions |
| Prerequisites missing | Report status table, stop on critical failures |
| ai-api not running | Guide startup with `tee` for log capture |
| ai-api won't start | Ask user to paste error or check `/tmp/ai-api-dev.log` |
| Credentials missing in opencode | Stop, ask user to add to `.env.local` |
| No ai-api log file | Suggest restarting with `tee`, skip ai-api log analysis |
| Both stacks show errors | Correlate timestamps to identify which side failed first |
