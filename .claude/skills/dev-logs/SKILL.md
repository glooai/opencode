---
name: dev-logs
description: Tail and search opencode dev logs for troubleshooting — filter by provider, service, level, or freeform pattern
argument-hint: '[gloo] [--level ERROR] [--lines 50] [--follow] [--service provider]'
---

# Dev Logs

Tail, search, and analyze opencode logs during `bun run dev` troubleshooting.

## Arguments

<arguments> #$ARGUMENTS </arguments>

**Parse arguments:**

- First positional arg — freeform grep pattern (e.g. `gloo`, `token`, `stream error`)
- `--level <LEVEL>` — filter to DEBUG, INFO, WARN, or ERROR (default: all)
- `--lines <N>` — number of recent lines to show (default: 50)
- `--follow` — continuously tail the log (use `tail -f`)
- `--service <name>` — filter to a specific service tag (e.g. `provider`, `llm`, `server`)
- `--since <duration>` — only show entries from the last N minutes (e.g. `5m`, `1h`)
- No arguments — show the last 50 lines of the most recent log

## Log Location

Opencode writes logs to the XDG data directory:

- **macOS:** `$HOME/.local/share/opencode/log/`
- **Linux:** `$HOME/.local/share/opencode/log/`

When running `bun run dev`, logs go to `dev.log`. Otherwise they are timestamped files like `2026-03-30T143948.log`.

## Execution

### Step 1 — Find the log file

```bash
LOG_DIR="$HOME/.local/share/opencode/log"
```

If `--follow` or the user is actively running `bun run dev`, use `dev.log`. Otherwise find the most recent timestamped log:

```bash
ls -t "$LOG_DIR"/*.log | head -1
```

Verify the file exists. If the log directory is missing, stop: "No opencode logs found. Is the app running? Expected logs at $LOG_DIR"

### Step 2 — Read and filter

Use a combination of the Read tool and Grep tool to search the log file. Prefer these over bash `grep`/`tail` for better user experience.

**Default (no args):** Read the last 50 lines of the log file.

**With pattern:** Use Grep to search for the pattern in the log file, showing context lines around matches.

**With `--level`:** Filter lines starting with the level prefix (e.g. `ERROR`, `WARN `).

**With `--service`:** Filter for `service=<name>` in log lines.

**With `--since`:** Calculate the cutoff timestamp, then filter log lines whose ISO timestamp is after the cutoff.

**With `--follow`:** Run `tail -f` on the log file via Bash, optionally piped through grep if a pattern is provided. Warn the user this will block until they cancel.

### Step 3 — Analyze and summarize

After showing the raw log output:

1. Count occurrences by level (INFO/WARN/ERROR)
2. Highlight any ERROR lines with a brief explanation of what they mean
3. If the pattern relates to a provider (e.g. `gloo`), trace the request lifecycle:
   - Token acquisition (look for `token acquired`)
   - Fetch requests (look for `gloo fetch` or similar)
   - Response status (look for `fetch failed` or `stream error`)
4. Flag any suspicious patterns:
   - Repeated errors in short succession (possible retry loop)
   - Token refresh failures
   - HTTP 4xx/5xx status codes
   - Streaming errors

### Step 4 — Suggest next steps

Based on what the logs show, suggest concrete debugging actions:

| Pattern | Suggestion |
|---|---|
| Token request failed | Check `GLOO_CLIENT_ID` and `GLOO_CLIENT_SECRET` env vars |
| 403 / insufficient permissions | Credentials may not have access to this model — try a different model or check account permissions |
| Streaming error occurred | Platform-side issue — try a different model to isolate, or report to Gloo platform team |
| No gloo log entries at all | Provider may not be loading — check env vars are set and restart the app |
| Token acquired but no fetch | SDK initialization issue — check the model ID is correct |
