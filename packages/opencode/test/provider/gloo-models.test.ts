/**
 * Integration test: verifies each Gloo AI model can handle streaming
 * requests — both plain text and with tool definitions (function calling).
 *
 * Skipped by default — requires GLOO_CLIENT_ID and GLOO_CLIENT_SECRET.
 * Run manually:
 *   GLOO_CLIENT_ID=… GLOO_CLIENT_SECRET=… bun test test/provider/gloo-models.test.ts --timeout 300000
 */
import { describe, test } from "bun:test"
import { createOpenAICompatible } from "@ai-sdk/openai-compatible"
import { streamText, tool, jsonSchema } from "ai"

const GLOO_CLIENT_ID = process.env.GLOO_CLIENT_ID ?? process.env.GLOO_AI_CLIENT_ID
const GLOO_CLIENT_SECRET = process.env.GLOO_CLIENT_SECRET ?? process.env.GLOO_AI_CLIENT_SECRET
const HAS_CREDENTIALS = !!(GLOO_CLIENT_ID && GLOO_CLIENT_SECRET)

const TOKEN_URL = "https://platform.ai.gloo.com/oauth2/token"
const BASE_URL = "https://platform.ai.gloo.com/ai/v2"

// All Gloo model IDs — keep in sync with provider.ts seed list
const GLOO_MODELS = [
  // Anthropic
  "gloo-anthropic-claude-haiku-4.5",
  "gloo-anthropic-claude-sonnet-4",
  "gloo-anthropic-claude-sonnet-4.5",
  "gloo-anthropic-claude-sonnet-4.6",
  "gloo-anthropic-claude-opus-4.5",
  "gloo-anthropic-claude-opus-4.6",
  // Google
  "gloo-google-gemini-2.5-flash-lite",
  "gloo-google-gemini-2.5-flash",
  "gloo-google-gemini-2.5-pro",
  // OpenAI
  "gloo-openai-gpt-5-nano",
  "gloo-openai-gpt-5-mini",
  "gloo-openai-gpt-4.1-mini",
  "gloo-openai-gpt-4.1",
  "gloo-openai-gpt-5.2",
  "gloo-openai-gpt-5.4",
  "gloo-openai-gpt-5.2-pro",
  // Open Source
  "gloo-meta-llama-3.1-8b-instruct",
  "gloo-meta-llama-4-maverick",
  "gloo-deepseek-chat-v3.1",
  "gloo-deepseek-v3.2",
  "gloo-deepseek-r1",
  "gloo-openai-gpt-oss-120b",
] as const

// Models the Gloo platform rejects when `tools` is in the request (verified
// 2026-04-27). Mirrors the `toolcall: false` overrides in
// packages/opencode/src/provider/provider.ts. Excluded from the tool-use suite
// but still exercised in the text-only suite.
const NO_TOOLCALL = new Set<string>([
  "gloo-deepseek-r1",
  "gloo-meta-llama-4-maverick",
  "gloo-meta-llama-3.1-8b-instruct",
])

// --- OAuth2 token management ---

let tokenCache: { accessToken: string; expiresAt: number } | null = null
let pendingTokenRequest: Promise<string> | null = null

async function fetchToken(): Promise<string> {
  const encoded = Buffer.from(
    `${encodeURIComponent(GLOO_CLIENT_ID!)}:${encodeURIComponent(GLOO_CLIENT_SECRET!)}`,
  ).toString("base64")

  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      Authorization: `Basic ${encoded}`,
    },
    body: new URLSearchParams({ grant_type: "client_credentials", scope: "api/access" }),
  })

  if (!res.ok) {
    const text = await res.text()
    throw new Error(`Gloo token request failed (${res.status}): ${text}`)
  }

  const data = (await res.json()) as { access_token: string; expires_in?: number }
  tokenCache = {
    accessToken: data.access_token,
    expiresAt: Date.now() + ((data.expires_in ?? 3600) - 60) * 1000,
  }
  return data.access_token
}

async function getToken(): Promise<string> {
  if (tokenCache && Date.now() < tokenCache.expiresAt) return tokenCache.accessToken
  if (!pendingTokenRequest) {
    pendingTokenRequest = fetchToken().finally(() => {
      pendingTokenRequest = null
    })
  }
  return pendingTokenRequest
}

// --- Provider setup ---

function createGlooProvider() {
  return createOpenAICompatible({
    name: "gloo",
    baseURL: BASE_URL,
    // @ts-expect-error Bun's fetch type includes `preconnect` not in standard RequestInit
    fetch: async (url: RequestInfo | URL, init?: RequestInit) => {
      const token = await getToken()
      const headers = new Headers(init?.headers)
      headers.set("Authorization", `Bearer ${token}`)
      return globalThis.fetch(url, { ...init, headers })
    },
  })
}

// --- Helpers ---

type StreamResult = {
  hasText: boolean
  hasToolCall: boolean
  partTypes: string[]
  errors: Array<{ message: string; cause?: string }>
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function consumeStream(stream: { fullStream: AsyncIterable<any> }): Promise<StreamResult> {
  const result: StreamResult = { hasText: false, hasToolCall: false, partTypes: [], errors: [] }
  const seen = new Set<string>()

  try {
    for await (const part of stream.fullStream) {
      if (!seen.has(part.type)) {
        seen.add(part.type)
        result.partTypes.push(part.type)
      }
      if (part.type === "text-delta") {
        // AI SDK v6: fullStream text-delta may use `textDelta`, `delta`, or `text`
        const p = part as Record<string, unknown>
        const text = (p.textDelta ?? p.delta ?? p.text ?? "") as string
        if (text.length > 0) result.hasText = true
      }
      if (part.type === "tool-call") {
        result.hasToolCall = true
      }
      if (part.type === "error") {
        const err = part.error
        result.errors.push({
          message: err instanceof Error ? err.message : String(err),
          cause: err instanceof Error && err.cause ? String(err.cause) : undefined,
        })
      }
    }
  } catch (err) {
    result.errors.push({
      message: err instanceof Error ? err.message : String(err),
      cause: err instanceof Error && err.cause ? String(err.cause) : undefined,
    })
  }

  return result
}

function formatDiag(result: StreamResult): string {
  return `partTypes=[${result.partTypes.join(",")}]`
}

// --- Test suites ---

const describeIfCreds = HAS_CREDENTIALS ? describe : describe.skip

describeIfCreds("gloo AI models — text streaming (no tools)", () => {
  const provider = createGlooProvider()

  for (const modelId of GLOO_MODELS) {
    test(
      modelId,
      async () => {
        const model = provider.chatModel(modelId)

        const stream = streamText({
          model,
          messages: [{ role: "user", content: "Say hello in one sentence." }],
          maxOutputTokens: 128,
          abortSignal: AbortSignal.timeout(60_000),
        })

        const result = await consumeStream(stream)
        const diag = formatDiag(result)

        if (result.errors.length > 0) {
          const msgs = result.errors.map((e) => e.cause ? `${e.message} (cause: ${e.cause})` : e.message).join("; ")
          throw new Error(`[text] ${modelId}: ${msgs} | ${diag}`)
        }

        if (!result.hasText) {
          throw new Error(`[text] ${modelId}: no text received | ${diag}`)
        }
      },
      { timeout: 90_000 },
    )
  }
})

describeIfCreds("gloo AI models — streaming with tool use", () => {
  const provider = createGlooProvider()

  const testTool = tool({
    description: "Get the current weather for a city",
    inputSchema: jsonSchema({
      type: "object" as const,
      properties: {
        city: { type: "string", description: "The city name" },
      },
      required: ["city"],
    }),
  })

  for (const modelId of GLOO_MODELS) {
    if (NO_TOOLCALL.has(modelId)) continue
    test(
      modelId,
      async () => {
        const model = provider.chatModel(modelId)

        const stream = streamText({
          model,
          messages: [{ role: "user", content: "What is the weather in San Francisco? Use the weather tool." }],
          tools: { weather: testTool },
          maxOutputTokens: 512,
          abortSignal: AbortSignal.timeout(60_000),
        })

        const result = await consumeStream(stream)
        const diag = formatDiag(result)

        if (result.errors.length > 0) {
          const msgs = result.errors.map((e) => e.cause ? `${e.message} (cause: ${e.cause})` : e.message).join("; ")
          throw new Error(`[tools] ${modelId}: ${msgs} | ${diag}`)
        }

        if (!result.hasText && !result.hasToolCall) {
          throw new Error(`[tools] ${modelId}: no text or tool-call received | ${diag}`)
        }
      },
      { timeout: 90_000 },
    )
  }
})
