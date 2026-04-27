#!/usr/bin/env bun
/**
 * Gloo AI provider end-to-end smoke verifier.
 *
 * Run from packages/opencode (or repo root via `bun run verify:gloo`):
 *   bun run script/verify-gloo.ts             # hits platform.ai.gloo.com
 *   bun run script/verify-gloo.ts --local     # hits http://localhost:8000 (local ai-api)
 *
 * Exits 0 on full pass; 1 on any failure or expected-rejection mismatch.
 *
 * Companion to test/provider/gloo-models.test.ts (full 23-model matrix).
 * This script runs a small representative set with prettier output for
 * day-to-day verification.
 */
import { execSync } from "node:child_process"
import { readFileSync } from "node:fs"
import { resolve, dirname } from "node:path"
import { fileURLToPath } from "node:url"
import { createOpenAICompatible } from "@ai-sdk/openai-compatible"
import { jsonSchema, streamText, tool } from "ai"

// --- Tiny ANSI helpers (no chalk dep) -----------------------------------

const isTTY = process.stdout.isTTY
const c = (n: number) => (s: string) => (isTTY ? `\x1b[${n}m${s}\x1b[0m` : s)
const green = c(32)
const red = c(31)
const yellow = c(33)
const dim = c(2)
const bold = c(1)
const PASS = green("✅")
const FAIL = red("❌")

// --- CLI parsing --------------------------------------------------------

const args = new Set(process.argv.slice(2))
const isLocal = args.has("--local")

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url))
const PKG_DIR = resolve(SCRIPT_DIR, "..")
const REPO_ROOT = resolve(PKG_DIR, "..", "..")
const PROVIDER_TS = resolve(PKG_DIR, "src/provider/provider.ts")

// --- Result tracking ----------------------------------------------------

type Result = {
  name: string
  ok: boolean
  detail: string
  durationMs?: number
}
const results: Result[] = []
const log = (r: Result) => {
  results.push(r)
  const icon = r.ok ? PASS : FAIL
  const dur = r.durationMs !== undefined ? dim(`  ${r.durationMs}ms`) : ""
  console.log(`${icon}  ${bold(r.name.padEnd(14))}  ${r.detail}${dur}`)
}

// --- Step 1: build sanity ----------------------------------------------

function checkBuildSanity() {
  let branch = "unknown"
  let head = "unknown"
  try {
    branch = execSync("git rev-parse --abbrev-ref HEAD", { cwd: REPO_ROOT }).toString().trim()
    head = execSync("git rev-parse --short HEAD", { cwd: REPO_ROOT }).toString().trim()
  } catch (e) {
    log({ name: "Branch", ok: false, detail: `git unavailable: ${(e as Error).message}` })
    return
  }
  log({ name: "Branch", ok: true, detail: `${branch} @ ${head}` })

  const bunVersion = process.versions.bun ?? "not-bun"
  const ok = bunVersion !== "not-bun"
  log({
    name: "Bun",
    ok,
    detail: ok ? bunVersion : "not running under bun (try: bun run verify:gloo)",
  })
}

// --- Step 2: env / creds ------------------------------------------------

function checkCreds(): { clientId: string; clientSecret: string; baseUrl: string } | null {
  const clientId = process.env.GLOO_CLIENT_ID ?? process.env.GLOO_AI_CLIENT_ID
  const clientSecret = process.env.GLOO_CLIENT_SECRET ?? process.env.GLOO_AI_CLIENT_SECRET
  const baseUrl = isLocal
    ? (process.env.GLOO_BASE_URL ?? "http://localhost:8000")
    : "https://platform.ai.gloo.com"

  if (!clientId || !clientSecret) {
    log({
      name: "Creds",
      ok: false,
      detail: "GLOO_CLIENT_ID and GLOO_CLIENT_SECRET must be set (try: `set -a && source .env.local && set +a`)",
    })
    return null
  }

  log({
    name: "Creds",
    ok: true,
    detail: `client_id=${clientId.slice(0, 8)}…  secret_len=${clientSecret.length}  baseUrl=${baseUrl}${isLocal ? yellow("  [local]") : ""}`,
  })
  return { clientId, clientSecret, baseUrl }
}

// --- Step 3: static catalog assertions ---------------------------------

function checkCatalog() {
  const src = readFileSync(PROVIDER_TS, "utf8")

  // Find glooModelDefs array; extract model id strings + presence of toolcall: false
  const arrayMatch = src.match(/glooModelDefs:[\s\S]*?=\s*\[([\s\S]*?)\]\n\s+const glooModels/)
  if (!arrayMatch) {
    log({
      name: "Catalog",
      ok: false,
      detail: "could not locate glooModelDefs in provider.ts (script needs an update)",
    })
    return
  }
  const arrayBody = arrayMatch[1]
  const ids = [...arrayBody.matchAll(/id:\s*"([^"]+)"/g)].map((m) => m[1])
  const noToolcall = [...arrayBody.matchAll(/id:\s*"([^"]+)"[^}]*toolcall:\s*false/g)].map(
    (m) => m[1],
  )

  const expectedNoToolcall = new Set([
    "gloo-deepseek-r1",
    "gloo-meta-llama-4-maverick",
    "gloo-meta-llama-3.1-8b-instruct",
  ])
  const missingFlag = [...expectedNoToolcall].filter((id) => !noToolcall.includes(id))
  const unexpectedFlag = noToolcall.filter((id) => !expectedNoToolcall.has(id))

  // Models that should NOT be in the catalog (removed from Gloo platform)
  const expectedAbsent = ["gloo-google-gemini-3-pro-preview"]
  const stillPresent = expectedAbsent.filter((id) => ids.includes(id))

  if (missingFlag.length || unexpectedFlag.length || stillPresent.length) {
    const issues: string[] = []
    if (missingFlag.length) issues.push(`missing toolcall:false → ${missingFlag.join(", ")}`)
    if (unexpectedFlag.length) issues.push(`unexpected toolcall:false → ${unexpectedFlag.join(", ")}`)
    if (stillPresent.length) issues.push(`should be removed → ${stillPresent.join(", ")}`)
    log({ name: "Catalog", ok: false, detail: issues.join("; ") })
    return
  }
  log({
    name: "Catalog",
    ok: true,
    detail: `${ids.length} models seeded; toolcall:false on ${noToolcall.length} (deepseek-r1, llama-4-maverick, llama-3.1-8b-instruct)`,
  })
}

// --- Step 4: live OAuth + streaming smoke ------------------------------

type StreamCheck = {
  modelId: string
  withTools: boolean
  expect: "stream" | "reject"
}

const SMOKE: StreamCheck[] = [
  { modelId: "gloo-anthropic-claude-sonnet-4.6", withTools: false, expect: "stream" },
  { modelId: "gloo-anthropic-claude-sonnet-4.6", withTools: true, expect: "stream" },
  { modelId: "gloo-openai-gpt-4.1", withTools: true, expect: "stream" }, // headline regression-fix
  { modelId: "gloo-deepseek-r1", withTools: false, expect: "stream" },
  { modelId: "gloo-deepseek-r1", withTools: true, expect: "reject" },
]

async function getToken(creds: { clientId: string; clientSecret: string; baseUrl: string }) {
  if (isLocal) {
    // Local ai-api accepts any Bearer token in ENVIRONMENT=local mode
    return creds.clientId
  }
  const encoded = Buffer.from(
    `${encodeURIComponent(creds.clientId)}:${encodeURIComponent(creds.clientSecret)}`,
  ).toString("base64")
  const res = await fetch(`${creds.baseUrl}/oauth2/token`, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      Authorization: `Basic ${encoded}`,
    },
    body: new URLSearchParams({ grant_type: "client_credentials", scope: "api/access" }),
  })
  if (!res.ok) {
    const body = await res.text().catch(() => "")
    throw new Error(`token request failed (${res.status}): ${body.slice(0, 200)}`)
  }
  const data = (await res.json()) as { access_token: string }
  return data.access_token
}

async function runSmoke(creds: { clientId: string; clientSecret: string; baseUrl: string }) {
  const tStart = Date.now()
  let token: string
  try {
    token = await getToken(creds)
  } catch (err) {
    log({ name: "Token", ok: false, detail: (err as Error).message })
    return
  }
  log({
    name: "Token",
    ok: true,
    detail: `${isLocal ? "local-mode shortcut (no OAuth2)" : "OAuth2 client_credentials grant"} → ${token.slice(0, 12)}…`,
    durationMs: Date.now() - tStart,
  })

  const provider = createOpenAICompatible({
    name: "gloo",
    baseURL: `${creds.baseUrl}/ai/v2`,
    headers: { Authorization: `Bearer ${token}` },
  })

  const weather = tool({
    description: "Get the current weather for a city",
    inputSchema: jsonSchema({
      type: "object" as const,
      properties: { city: { type: "string", description: "The city name" } },
      required: ["city"],
    }),
  })

  for (const check of SMOKE) {
    const t0 = Date.now()
    const tag = check.withTools ? "tools" : "text "
    const label = `${check.modelId.padEnd(36)} (${tag})`
    const verb = check.expect === "reject" ? "Reject" : "Stream"

    // For expected rejections we use a raw fetch to avoid the AI SDK's
    // verbose unhandled-rejection logging when the platform returns 4xx.
    if (check.expect === "reject") {
      try {
        const res = await fetch(`${creds.baseUrl}/ai/v2/chat/completions`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${token}`,
          },
          body: JSON.stringify({
            model: check.modelId,
            messages: [
              { role: "user", content: "What is the weather in San Francisco? Use the weather tool." },
            ],
            tools: [
              {
                type: "function",
                function: {
                  name: "weather",
                  description: "Get the current weather for a city",
                  parameters: {
                    type: "object",
                    properties: { city: { type: "string" } },
                    required: ["city"],
                  },
                },
              },
            ],
            stream: false,
            max_tokens: 64,
          }),
          signal: AbortSignal.timeout(30_000),
        })
        if (res.ok) {
          log({
            name: verb,
            ok: false,
            detail: `${label} → expected 4xx but got HTTP ${res.status}`,
            durationMs: Date.now() - t0,
          })
          continue
        }
        const body = await res.text().catch(() => "")
        const msg = body.match(/"message"\s*:\s*"([^"]+)"/)?.[1] ?? `HTTP ${res.status}`
        log({
          name: verb,
          ok: true,
          detail: `${label} → ${dim(`${res.status} ${msg.slice(0, 80)}`)}`,
          durationMs: Date.now() - t0,
        })
      } catch (err) {
        log({
          name: verb,
          ok: false,
          detail: `${label} → ${red((err as Error).message.slice(0, 200))}`,
          durationMs: Date.now() - t0,
        })
      }
      continue
    }

    try {
      const stream = streamText({
        model: provider.chatModel(check.modelId),
        messages: [
          {
            role: "user",
            content: check.withTools
              ? "What is the weather in San Francisco? Use the weather tool."
              : "Say hello in one sentence.",
          },
        ],
        tools: check.withTools ? { weather } : undefined,
        maxOutputTokens: check.withTools ? 256 : 64,
        abortSignal: AbortSignal.timeout(45_000),
      })

      let hadText = false
      let hadToolCall = false
      let streamErr: { message: string; cause?: string } | null = null
      for await (const part of stream.fullStream) {
        if (part.type === "text-delta" || part.type === "reasoning-delta") hadText = true
        if (part.type === "tool-call" || part.type === "tool-input-start") hadToolCall = true
        if (part.type === "error") {
          const e = (part as any).error
          streamErr = {
            message: e?.message ?? String(e),
            cause: e?.cause ? String(e.cause) : undefined,
          }
        }
      }

      if (streamErr) {
        log({
          name: verb,
          ok: false,
          detail: `${label} → ${red(streamErr.message)}${streamErr.cause ? dim(`  cause=${streamErr.cause}`) : ""}`,
          durationMs: Date.now() - t0,
        })
        continue
      }
      if (!hadText && !hadToolCall) {
        log({
          name: verb,
          ok: false,
          detail: `${label} → no text or tool-call received`,
          durationMs: Date.now() - t0,
        })
        continue
      }
      log({
        name: verb,
        ok: true,
        detail: `${label} → ${hadToolCall ? "tool-call" : "text"} ok`,
        durationMs: Date.now() - t0,
      })
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err)
      log({
        name: verb,
        ok: false,
        detail: `${label} → ${red(msg.split("\n")[0].slice(0, 200))}`,
        durationMs: Date.now() - t0,
      })
    }
  }
}

// --- Main ---------------------------------------------------------------

async function main() {
  console.log(bold(`\nGloo AI provider verifier · ${isLocal ? "LOCAL" : "PRODUCTION"}\n`))
  checkBuildSanity()
  const creds = checkCreds()
  checkCatalog()
  if (creds) await runSmoke(creds)

  const failed = results.filter((r) => !r.ok)
  const passed = results.length - failed.length
  console.log()
  if (failed.length === 0) {
    console.log(green(bold(`PASS  ${passed}/${results.length} checks green`)))
    process.exit(0)
  } else {
    console.log(red(bold(`FAIL  ${failed.length} of ${results.length} checks red`)))
    for (const r of failed) console.log(red(`        • ${r.name}: ${r.detail.replace(/\x1b\[\d+m/g, "")}`))
    process.exit(1)
  }
}

main().catch((err) => {
  console.error(red(bold("\nverifier crashed:")), err)
  process.exit(2)
})
