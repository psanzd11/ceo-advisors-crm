import { createClient } from "@supabase/supabase-js";
import { ASSISTANT_INSTRUCTIONS, buildContextBlock, buildMetadataBlock, ScopedData } from "./prompt.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const CLAUDE_MODEL = Deno.env.get("CLAUDE_MODEL") ?? "claude-sonnet-4-6";
const RATE_LIMIT_MAX = parseInt(Deno.env.get("CHAT_RATE_LIMIT_MAX") ?? "30", 10);
const MAX_BODY_BYTES = 200_000;
const MAX_SCOPED_BYTES = 100_000;

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonError(status: number, message: string, extra: Record<string, unknown> = {}): Response {
  return new Response(JSON.stringify({ error: message, ...extra }), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  // 1. CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  if (req.method !== "POST") {
    return jsonError(405, "Method not allowed");
  }

  // 2. Auth
  const authHeader = req.headers.get("Authorization") ?? "";
  const jwt = authHeader.replace(/^Bearer\s+/i, "");
  if (!jwt) {
    return jsonError(401, "Missing Authorization header");
  }

  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const { data: userData, error: userErr } = await adminClient.auth.getUser(jwt);
  if (userErr || !userData?.user) {
    return jsonError(401, "Invalid JWT");
  }
  const userId = userData.user.id;

  // 3. Rate limit (Postgres RPC)
  const hourBucket = Math.floor(Date.now() / 3_600_000);
  const { data: rlData, error: rlErr } = await adminClient.rpc("chat_rate_limit_check", {
    p_user: userId,
    p_bucket: hourBucket,
    p_max: RATE_LIMIT_MAX,
  });
  if (rlErr) {
    console.error("rate_limit_rpc_error", rlErr);
    return jsonError(500, "Rate limit check failed");
  }
  const rl = Array.isArray(rlData) ? rlData[0] : rlData;
  if (!rl?.allowed) {
    return new Response(
      JSON.stringify({ error: "Rate limit exceeded", reset_at: rl?.reset_at }),
      {
        status: 429,
        headers: {
          ...CORS_HEADERS,
          "Content-Type": "application/json",
          "X-RateLimit-Reset": String(rl?.reset_at ?? ""),
        },
      },
    );
  }

  // 4. Parse + validate body
  const rawBody = await req.text();
  if (rawBody.length > MAX_BODY_BYTES) {
    return jsonError(413, "Body too large");
  }

  let body: { messages?: Array<{ role: string; content: string }>; scopedData?: ScopedData };
  try {
    body = JSON.parse(rawBody);
  } catch {
    return jsonError(400, "Invalid JSON");
  }

  const messages = body.messages ?? [];
  const scopedData = body.scopedData ?? {};

  if (!Array.isArray(messages) || messages.length === 0) {
    return jsonError(400, "messages must be a non-empty array");
  }
  if (messages.length > 60) {
    return jsonError(400, "messages exceeds cap of 60");
  }
  if (messages[messages.length - 1].role !== "user") {
    return jsonError(400, "Last message must be from user");
  }
  for (const m of messages) {
    if (m.role !== "user" && m.role !== "assistant") {
      return jsonError(400, "Invalid message role");
    }
    if (typeof m.content !== "string" || m.content.length === 0) {
      return jsonError(400, "Invalid message content");
    }
  }

  if (typeof scopedData !== "object" || scopedData === null || Array.isArray(scopedData)) {
    return jsonError(400, "scopedData must be an object");
  }
  const scopedJson = JSON.stringify(scopedData);
  if (scopedJson.length > MAX_SCOPED_BYTES) {
    return jsonError(413, `scopedData exceeds ${MAX_SCOPED_BYTES} bytes`);
  }

  // 5. Build system prompt blocks
  const userMeta = {
    date: new Date().toISOString().slice(0, 10),
    userName: userData.user.email ?? "consultor",
    userCode: (userData.user.user_metadata?.code as string) ?? "?",
    userRole: (userData.user.user_metadata?.role as string) ?? "Advisor",
  };

  const systemBlocks = [
    { type: "text", text: ASSISTANT_INSTRUCTIONS, cache_control: { type: "ephemeral" } },
    { type: "text", text: buildContextBlock(scopedData), cache_control: { type: "ephemeral" } },
    { type: "text", text: buildMetadataBlock(userMeta) },
  ];

  // 6. Call Anthropic with streaming
  let anthropicRes: Response;
  try {
    anthropicRes = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: CLAUDE_MODEL,
        max_tokens: 2048,
        stream: true,
        system: systemBlocks,
        messages,
      }),
    });
  } catch (e) {
    console.error("anthropic_fetch_error", e);
    return jsonError(502, "Anthropic upstream unreachable");
  }

  if (!anthropicRes.ok || !anthropicRes.body) {
    const errText = await anthropicRes.text().catch(() => "");
    console.error("anthropic_error", anthropicRes.status, errText);
    return jsonError(502, "Anthropic upstream error", { upstream_status: anthropicRes.status });
  }

  // 7. Stream SSE relay → cliente
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      const reader = anthropicRes.body!.getReader();
      let buffer = "";
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });

          let nlIdx: number;
          while ((nlIdx = buffer.indexOf("\n")) >= 0) {
            const line = buffer.slice(0, nlIdx);
            buffer = buffer.slice(nlIdx + 1);
            if (!line.startsWith("data: ")) continue;
            const payload = line.slice(6).trim();
            if (!payload || payload === "[DONE]") continue;
            try {
              const parsed = JSON.parse(payload);
              if (parsed.type === "content_block_delta" && parsed.delta?.type === "text_delta") {
                controller.enqueue(encoder.encode(`data: ${JSON.stringify({ text: parsed.delta.text })}\n\n`));
              }
            } catch {
              // Ignora eventos malformados.
            }
          }
        }
        controller.enqueue(encoder.encode("data: [DONE]\n\n"));
      } catch (e) {
        console.error("stream_relay_error", e);
        controller.enqueue(encoder.encode(`data: ${JSON.stringify({ error: "stream interrupted" })}\n\n`));
      } finally {
        controller.close();
      }
    },
  });

  return new Response(stream, {
    headers: {
      ...CORS_HEADERS,
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      "Connection": "keep-alive",
    },
  });
});
