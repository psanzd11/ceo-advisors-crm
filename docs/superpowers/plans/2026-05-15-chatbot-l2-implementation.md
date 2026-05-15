# Chatbot IA L2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implementar un asistente IA accesible desde el CRM que responde preguntas analíticas (read-only, alcance L2) sobre los datos del consultor logueado.

**Architecture:** Cliente HTML embebe widget (burbuja flotante + popup) → Supabase Edge Function (`chat-assistant`) custodia API key de Anthropic, valida JWT, aplica rate limit vía RPC Postgres, hace stream relay SSE de la respuesta de Claude. Contexto enviado en cada turno como JSON inline en system prompt con `cache_control: ephemeral`.

**Tech Stack:** Vanilla JS (cliente), Deno + TypeScript (edge function), Supabase Edge Functions, Postgres RPC, Anthropic Messages API (claude-sonnet-4-6) con streaming SSE y prompt caching.

**Spec:** `docs/superpowers/specs/2026-05-15-chatbot-l2-design.md`

---

## File Structure

| Archivo | Acción | Responsabilidad |
|---|---|---|
| `supabase_migrations/011_chat_rate_limits.sql` | **Crear** | Tabla + RPC atómico para rate limiting |
| `supabase/functions/chat-assistant/deno.json` | **Crear** | Imports map del edge function |
| `supabase/functions/chat-assistant/index.ts` | **Crear** | Handler completo: auth + rate limit + prompt + stream relay |
| `supabase/functions/chat-assistant/prompt.ts` | **Crear** | System prompt instructions (separado para que sea fácil iterar sobre el prompt sin tocar el handler) |
| `index.html` | **Modificar** (línea ~7453, antes de `/* boot */`) | Insertar HTML + CSS + JS del widget |
| `CLAUDE.md` | **Modificar** | Añadir sección breve sobre arquitectura del chatbot |

---

## Phase 0 — Pre-flight

### Task 0.1: Revisar cambios uncommitted previos

**Files:** Ninguno (solo lectura).

- [ ] **Step 1: Comprobar git status**

```bash
git status
```

Expected output incluye:
```
modified:   index.html
Untracked files:
        supabase_migrations/010_upsert_consultants_skip_unique_violation.sql
```

- [ ] **Step 2: Decidir qué hacer con los cambios pendientes**

Ver el diff de `index.html` y la migration 010:
```bash
git diff index.html | head -100
cat supabase_migrations/010_upsert_consultants_skip_unique_violation.sql
```

Si los cambios son intencionales y completos → **commit aparte** con mensaje descriptivo antes de empezar el chatbot. Si son work-in-progress no relacionados → **stash**:
```bash
git stash push -m "WIP pre-chatbot $(date +%Y-%m-%d)"
```

Si están listos para commit y son la migration 010 (que ya fue aplicada según su header), commitear:
```bash
git add supabase_migrations/010_upsert_consultants_skip_unique_violation.sql index.html
git commit -m "F15.5: migration 010 (consultants unique_violation safe upsert)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

- [ ] **Step 3: Confirmar working tree limpio**

```bash
git status
```

Expected: `nothing to commit, working tree clean`.

---

## Phase 1 — Migration `011_chat_rate_limits.sql`

### Task 1.1: Crear el archivo de migration

**Files:**
- Create: `supabase_migrations/011_chat_rate_limits.sql`

- [ ] **Step 1: Crear el archivo con la SQL completa**

```sql
-- F-Chatbot: tabla + RPC atómico para rate limiting del chatbot IA.
-- Cada usuario tiene un cap de 30 mensajes por hora.
-- La edge function chat-assistant llama al RPC en cada turno.
--
-- Aplicada: <fecha-real-de-aplicación> vía MCP (mcp__claude_ai_Supabase__apply_migration)

create table if not exists public.chat_rate_limits (
  user_id     uuid not null,
  hour_bucket integer not null,
  count       integer not null default 0,
  primary key (user_id, hour_bucket)
);

create index if not exists chat_rate_limits_bucket_idx
  on public.chat_rate_limits (hour_bucket);

-- RLS: solo accesible desde service role. El cliente nunca consulta esta tabla
-- directamente; solo la edge function vía RPC.
alter table public.chat_rate_limits enable row level security;

-- RPC atómico: incrementa el contador del bucket y devuelve si está dentro del límite.
-- security definer para que el authenticated role pueda invocarlo sin acceso directo
-- a la tabla.
create or replace function public.chat_rate_limit_check(
  p_user   uuid,
  p_bucket integer,
  p_max    integer
) returns table(allowed boolean, current_count integer, reset_at bigint)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  insert into public.chat_rate_limits (user_id, hour_bucket, count)
  values (p_user, p_bucket, 1)
  on conflict (user_id, hour_bucket)
  do update set count = chat_rate_limits.count + 1
  returning count into v_count;

  return query select
    (v_count <= p_max)::boolean,
    v_count,
    ((p_bucket + 1) * 3600)::bigint;
end;
$$;

grant execute on function public.chat_rate_limit_check(uuid, integer, integer) to authenticated;

-- Limpieza opcional: los buckets viejos (>48h) no tienen valor.
-- Si en el futuro la tabla crece, considerar pg_cron diario:
--   delete from public.chat_rate_limits where hour_bucket < (extract(epoch from now())/3600 - 48)::int;
```

- [ ] **Step 2: Verificar sintaxis SQL leyendo el archivo**

```bash
cat supabase_migrations/011_chat_rate_limits.sql | head -50
```

Verificar que no hay typos obvios (paréntesis, comillas).

### Task 1.2: Aplicar la migration via MCP

- [ ] **Step 1: Llamar a apply_migration con el contenido del archivo**

Usar la herramienta MCP `mcp__claude_ai_Supabase__apply_migration`:
- `project_id`: `rtusnruywsmbbzejxooi`
- `name`: `chat_rate_limits`
- `query`: el contenido completo del archivo (todo el SQL).

Expected: respuesta sin error.

- [ ] **Step 2: Verificar que la tabla existe**

Usar `mcp__claude_ai_Supabase__list_tables` con `schemas: ['public']`. Debe aparecer `chat_rate_limits`.

O via execute_sql:
```sql
select column_name, data_type
from information_schema.columns
where table_schema = 'public' and table_name = 'chat_rate_limits'
order by ordinal_position;
```

Expected: 3 filas — `user_id` (uuid), `hour_bucket` (integer), `count` (integer).

- [ ] **Step 3: Verificar que el RPC funciona**

```sql
select * from public.chat_rate_limit_check(
  '00000000-0000-0000-0000-000000000001'::uuid,
  extract(epoch from now())::int / 3600,
  30
);
```

Expected: una fila con `allowed=true`, `current_count=1`, `reset_at` ≈ próxima hora en epoch seconds. Llamar otra vez y verificar `current_count=2`.

- [ ] **Step 4: Cleanup del test**

```sql
delete from public.chat_rate_limits where user_id = '00000000-0000-0000-0000-000000000001';
```

### Task 1.3: Commit de la migration

- [ ] **Step 1: Actualizar el header del archivo con la fecha real de aplicación**

Editar `supabase_migrations/011_chat_rate_limits.sql` para reemplazar `<fecha-real-de-aplicación>` con la fecha actual (ej. `2026-05-15`).

- [ ] **Step 2: Commit**

```bash
git add supabase_migrations/011_chat_rate_limits.sql
git commit -m "F-Chatbot 1/N: migration 011 (chat_rate_limits table + RPC)

Tabla + RPC atomico chat_rate_limit_check(user, hour_bucket, max) para
rate limiting del chatbot. Aplicada via MCP.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Phase 2 — Edge Function `chat-assistant`

### Task 2.1: Scaffold de la edge function

**Files:**
- Create: `supabase/functions/chat-assistant/deno.json`

- [ ] **Step 1: Crear directorio**

```bash
mkdir -p "supabase/functions/chat-assistant"
```

- [ ] **Step 2: Crear `deno.json` con imports map**

Archivo `supabase/functions/chat-assistant/deno.json`:

```json
{
  "imports": {
    "std/": "https://deno.land/std@0.224.0/",
    "@supabase/supabase-js": "https://esm.sh/@supabase/supabase-js@2.45.4"
  }
}
```

### Task 2.2: Crear `prompt.ts` con instrucciones del asistente

**Files:**
- Create: `supabase/functions/chat-assistant/prompt.ts`

- [ ] **Step 1: Escribir el módulo de prompt**

Archivo `supabase/functions/chat-assistant/prompt.ts`:

```typescript
// System prompt del asistente IA del CRM CEO Advisors.
// Aislado en este módulo para facilitar iteración sin tocar el handler.

export const ASSISTANT_INSTRUCTIONS = `Eres el asistente IA del CEO Advisors CRM. El usuario es un consultor del equipo que está consultando sus propios datos (deals, clientes, empresas, actividades, pupilos a su cargo).

REGLAS:
- Responde SIEMPRE en español, salvo que el usuario use otro idioma.
- Tu rol es analizar y explicar los datos del usuario, no proponer cambios ni ejecutar acciones. Si te piden crear/editar/borrar algo, responde: "Esa acción no está disponible aún. Hazlo desde el CRM directamente."
- Cuando muestres listas de >3 items, usa una tabla markdown.
- Sé conciso: respuestas de <120 palabras salvo que el análisis lo requiera.
- Si la pregunta no es sobre el CRM, redirige amablemente: "Puedo ayudarte con análisis sobre tus deals, clientes, empresas, actividades y pupilos."
- Las fechas de los datos son ISO (YYYY-MM-DD).
- 'splits' en deals indica cómo se reparte la atribución entre consultores.
- 'is_demo: true' indica dato de demo, generalmente irrelevante para análisis real.

FORMATO:
- Markdown ligero: **negrita**, listas, tablas, \`code\`.
- NUNCA HTML directo.
- Si hay ambigüedad en la pregunta, pide una aclaración antes de responder.`;

export interface ScopedData {
  deals?: unknown[];
  clients?: unknown[];
  companies?: unknown[];
  activities?: unknown[];
  pupilos?: unknown[];
  consultants?: unknown[];
}

export function buildContextBlock(data: ScopedData): string {
  return `DATOS DEL USUARIO (JSON):
\`\`\`json
${JSON.stringify(data)}
\`\`\``;
}

export function buildMetadataBlock(meta: { date: string; userName: string; userRole: string; userCode: string }): string {
  return `METADATOS DE LA SESIÓN:
- Fecha actual: ${meta.date}
- Usuario: ${meta.userName} (${meta.userCode}, rol: ${meta.userRole})`;
}
```

### Task 2.3: Crear el handler principal `index.ts` — esqueleto + CORS + auth

**Files:**
- Create: `supabase/functions/chat-assistant/index.ts`

- [ ] **Step 1: Crear el archivo con CORS + verificación de JWT**

Archivo `supabase/functions/chat-assistant/index.ts`:

```typescript
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

  // 4. Parse + validate body (continuará en Task 2.4)
  return jsonError(501, "Body handler not implemented yet");
});
```

- [ ] **Step 2: Iniciar el servidor local para verificación**

```bash
cd "supabase/functions" 2>/dev/null || true
supabase functions serve chat-assistant --no-verify-jwt --env-file ../../.env.functions.local
```

(Para `--env-file` crear `.env.functions.local` con `ANTHROPIC_API_KEY=sk-ant-test`. Esto solo se usa local.)

- [ ] **Step 3: Smoke test del CORS preflight**

En otra terminal:

```bash
curl -i -X OPTIONS http://localhost:54321/functions/v1/chat-assistant \
  -H "Origin: http://localhost"
```

Expected: HTTP 204 con header `Access-Control-Allow-Origin: *`.

- [ ] **Step 4: Smoke test sin auth → 401**

```bash
curl -i -X POST http://localhost:54321/functions/v1/chat-assistant \
  -H "Content-Type: application/json" -d '{}'
```

Expected: HTTP 401 con body `{"error":"Missing Authorization header"}`.

### Task 2.4: Body validation + parse

- [ ] **Step 1: Reemplazar el `return jsonError(501, ...)` del paso anterior con la validación**

Editar `supabase/functions/chat-assistant/index.ts`. Sustituir la línea final del handler:

```typescript
  // 4. Parse + validate body (continuará en Task 2.4)
  return jsonError(501, "Body handler not implemented yet");
```

por:

```typescript
  // 4. Parse + validate body
  const rawBody = await req.text();
  if (rawBody.length > MAX_BODY_BYTES) {
    return jsonError(413, "Body too large");
  }

  let body: { messages?: Array<{role: string; content: string}>; scopedData?: ScopedData };
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

  // 5. Build prompt + call Anthropic (continuará en Task 2.5)
  return jsonError(501, "Anthropic call not implemented yet");
```

- [ ] **Step 2: Verificar reload del server**

`supabase functions serve` recarga al guardar. Verificar terminal por errores de compilación.

- [ ] **Step 3: Smoke test con body inválido**

Obtener un JWT real primero — desde el navegador del CRM ya logueado, abrir DevTools console:
```js
(await sb.auth.getSession()).data.session.access_token
```
Copiar al clipboard.

```bash
JWT="<pega aquí>"
curl -i -X POST http://localhost:54321/functions/v1/chat-assistant \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{}'
```

Expected: HTTP 400 con `{"error":"messages must be a non-empty array"}`.

- [ ] **Step 4: Smoke test con body válido**

```bash
curl -i -X POST http://localhost:54321/functions/v1/chat-assistant \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"hola"}],"scopedData":{"deals":[]}}'
```

Expected: HTTP 501 con `{"error":"Anthropic call not implemented yet"}`. (Auth + rate limit pasan.)

### Task 2.5: Llamada a Anthropic con streaming SSE

- [ ] **Step 1: Sustituir el placeholder por la llamada real**

En `supabase/functions/chat-assistant/index.ts`, sustituir:

```typescript
  // 5. Build prompt + call Anthropic (continuará en Task 2.5)
  return jsonError(501, "Anthropic call not implemented yet");
```

por:

```typescript
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
```

- [ ] **Step 2: Verificar reload sin errores**

Mirar la terminal de `supabase functions serve`. No debe haber errores TypeScript.

- [ ] **Step 3: Smoke test con Anthropic real**

Asegurarse de que `.env.functions.local` tiene la `ANTHROPIC_API_KEY` real (no `sk-ant-test`). Reiniciar `supabase functions serve` con la key real:

```bash
ANTHROPIC_API_KEY=sk-ant-<key-real> supabase functions serve chat-assistant --no-verify-jwt
```

```bash
JWT="<jwt-real>"
curl -N -X POST http://localhost:54321/functions/v1/chat-assistant \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Di hola en una palabra"}],"scopedData":{}}'
```

Expected: stream SSE de tokens. Algo como:
```
data: {"text":"Hola"}

data: {"text":"!"}

data: [DONE]
```

### Task 2.6: Deploy de la edge function

- [ ] **Step 1: Verificar que el proyecto Supabase está vinculado**

```bash
supabase link --project-ref rtusnruywsmbbzejxooi
```

(Solo si no está ya vinculado. Si pide acceso, login con `supabase login`.)

- [ ] **Step 2: Set del secret**

```bash
supabase secrets set ANTHROPIC_API_KEY=sk-ant-<key-real-de-pablo>
```

Confirmar:
```bash
supabase secrets list
```

Expected: `ANTHROPIC_API_KEY` aparece (hash, no plaintext).

- [ ] **Step 3: Deploy**

```bash
supabase functions deploy chat-assistant
```

Expected: "Deployed Function chat-assistant on project rtusnruywsmbbzejxooi".

- [ ] **Step 4: Smoke remoto**

```bash
JWT="<jwt-real>"
curl -N -X POST "https://rtusnruywsmbbzejxooi.supabase.co/functions/v1/chat-assistant" \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hola"}],"scopedData":{}}'
```

Expected: mismo stream SSE que en local.

- [ ] **Step 5: Verificar logs en caso de fallo**

```bash
supabase functions logs chat-assistant --tail
```

Si hay error, leer trace y corregir.

### Task 2.7: Commit del edge function

- [ ] **Step 1: Commit**

```bash
git add supabase/functions/chat-assistant/
git commit -m "F-Chatbot 2/N: edge function chat-assistant

Deno function que verifica JWT, aplica rate limit via RPC, construye
system prompt con cache_control ephemeral y hace stream relay SSE
hacia Anthropic Messages API (sonnet-4-6).

Secret ANTHROPIC_API_KEY setado via supabase secrets set.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Phase 3 — Widget cliente en `index.html`

### Task 3.1: Localizar el punto de inserción y planificar la edición

**Files:**
- Read: `index.html:7445-7460` (zona alrededor de `/* boot */`)

- [ ] **Step 1: Localizar el marker exacto**

```bash
grep -n "/\* boot \*/" index.html
```

Expected: una sola coincidencia (línea ~7453). Si hay más de una, ABORTAR — investigar antes de seguir.

- [ ] **Step 2: Leer las 15 líneas antes y después del marker**

Confirmar que el marker `/* boot */` está precedido por el cierre de la función `applyAdminToolsVisibility()` y seguido por `state.authed=false;`.

### Task 3.2: Insertar el HTML del widget (FAB + popup)

**Files:**
- Modify: `index.html` — insertar después del `</footer>` o antes de `</body>` según el patrón.

- [ ] **Step 1: Localizar el `</body>` para insertar el HTML**

```bash
grep -n "</body>" index.html
```

Expected: una sola coincidencia. Si hay más de una, investigar.

- [ ] **Step 2: Insertar el HTML del widget justo antes de `</body>`**

Usar Edit tool con `old_string: "</body>"` y `new_string` que incluya el HTML + el `</body>` original:

```html
<!-- Chatbot IA L2 (F-Chatbot) -->
<button id="chatFab" type="button" aria-label="Asistente IA" title="Asistente IA">💬<span id="chatFabBadge" hidden></span></button>
<div id="chatPopup" role="dialog" aria-label="Asistente IA" hidden>
  <header>
    <h3>Asistente IA</h3>
    <div class="chat-actions">
      <button type="button" id="chatClear" aria-label="Borrar historial" title="Borrar historial">🗑</button>
      <button type="button" id="chatClose" aria-label="Cerrar" title="Cerrar">✕</button>
    </div>
  </header>
  <div id="chatMessages" aria-live="polite"></div>
  <form id="chatForm">
    <textarea id="chatInput" placeholder="Pregunta sobre tus deals, clientes, actividades…" rows="2" maxlength="2000"></textarea>
    <button type="submit" id="chatSend" aria-label="Enviar">↑</button>
  </form>
</div>
</body>
```

- [ ] **Step 3: Verificar que `</body>` sigue siendo único después del cambio**

```bash
grep -c "</body>" index.html
```

Expected: `1`.

### Task 3.3: Insertar el CSS del widget

**Files:**
- Modify: `index.html` — encontrar el `</style>` del bloque principal de CSS y añadir antes.

- [ ] **Step 1: Localizar el `</style>` principal**

```bash
grep -n "</style>" index.html
```

Suele ser una sola coincidencia (~líneas tempranas del archivo). Verificar.

- [ ] **Step 2: Insertar CSS antes del `</style>`**

Usar Edit con `old_string: "</style>"` y `new_string` que incluya el CSS + el `</style>` original:

```css
/* ────────── Chatbot IA Widget (F-Chatbot) ────────── */
#chatFab{
  position:fixed; right:20px; bottom:20px; z-index:9000;
  width:56px; height:56px; border-radius:50%;
  background:#0071e3; color:#fff; border:0; cursor:pointer;
  font-size:24px; display:flex; align-items:center; justify-content:center;
  box-shadow:0 6px 18px rgba(0,113,227,.45);
  transition:transform .15s ease;
}
#chatFab:hover{transform:scale(1.05)}
#chatFab[hidden]{display:none}
#chatFabBadge{
  position:absolute; top:6px; right:6px; width:10px; height:10px; border-radius:50%;
  background:#ff3b30; border:2px solid #fff;
}
#chatPopup{
  position:fixed; right:20px; bottom:88px; z-index:9001;
  width:400px; max-width:calc(100vw - 24px); height:520px; max-height:calc(100vh - 120px);
  background:var(--bg,#fff); color:var(--text,#1d1d1f);
  border:1px solid rgba(0,0,0,.08); border-radius:14px;
  box-shadow:0 16px 48px rgba(0,0,0,.18);
  display:flex; flex-direction:column; overflow:hidden;
}
#chatPopup[hidden]{display:none}
#chatPopup header{
  display:flex; align-items:center; justify-content:space-between;
  padding:10px 14px; border-bottom:1px solid rgba(0,0,0,.06);
  background:rgba(0,0,0,.02);
}
#chatPopup header h3{margin:0; font-size:14px; font-weight:600}
#chatPopup .chat-actions{display:flex; gap:6px}
#chatPopup .chat-actions button{
  background:none; border:0; cursor:pointer; padding:4px 8px;
  font-size:14px; color:var(--text,#1d1d1f); opacity:.65;
}
#chatPopup .chat-actions button:hover{opacity:1}
#chatMessages{
  flex:1; overflow-y:auto; padding:12px;
  display:flex; flex-direction:column; gap:8px;
  font-size:13px; line-height:1.45;
}
.chat-msg{max-width:88%; padding:8px 12px; border-radius:14px; word-wrap:break-word}
.chat-msg-user{align-self:flex-end; background:#0071e3; color:#fff; border-bottom-right-radius:4px}
.chat-msg-assistant{align-self:flex-start; background:#f0f0f2; color:#1d1d1f; border-bottom-left-radius:4px}
.chat-msg-error{align-self:stretch; background:#fff0f0; color:#c00; padding:8px 12px; border-radius:8px; font-size:12px}
.chat-msg-info{align-self:stretch; background:#fffbe6; color:#7a5a00; padding:6px 10px; border-radius:6px; font-size:11px}
.chat-msg-assistant table{border-collapse:collapse; margin:4px 0; font-size:12px}
.chat-msg-assistant th, .chat-msg-assistant td{border:1px solid rgba(0,0,0,.08); padding:3px 6px; text-align:left}
.chat-msg-assistant th{background:rgba(0,0,0,.04); font-weight:600}
.chat-msg-assistant code{background:rgba(0,0,0,.06); padding:1px 4px; border-radius:3px; font-family:ui-monospace,monospace; font-size:11px}
.chat-msg-assistant pre{background:rgba(0,0,0,.06); padding:6px 8px; border-radius:6px; overflow-x:auto; font-size:11px}
.chat-msg-assistant ul, .chat-msg-assistant ol{padding-left:18px; margin:4px 0}
.chat-msg-assistant a{color:#0071e3; text-decoration:underline}
.chat-cursor::after{content:"▌"; opacity:.5; animation:chat-blink 1s steps(1) infinite}
@keyframes chat-blink{50%{opacity:0}}
#chatForm{display:flex; gap:6px; padding:8px 10px; border-top:1px solid rgba(0,0,0,.06); background:rgba(0,0,0,.02)}
#chatInput{
  flex:1; resize:none; padding:6px 10px;
  border:1px solid rgba(0,0,0,.12); border-radius:8px;
  font-family:inherit; font-size:13px; background:var(--bg,#fff); color:var(--text,#1d1d1f);
}
#chatInput:focus{outline:none; border-color:#0071e3}
#chatSend{
  background:#0071e3; color:#fff; border:0; cursor:pointer;
  width:36px; border-radius:8px; font-size:16px; font-weight:600;
  align-self:stretch;
}
#chatSend:disabled{background:#999; cursor:not-allowed}
@media (max-width:480px){
  #chatPopup{right:8px; bottom:80px; width:calc(100vw - 16px); height:calc(100vh - 100px)}
}
</style>
```

- [ ] **Step 3: Verificar HTML aún válido**

```bash
tail -3 index.html
```

Expected: termina en `</html>`.

### Task 3.4: Insertar el módulo JS `ChatWidget` con state, render, parser, send

Este es el cambio más grande del cliente. Lo dividimos en sub-pasos para que el implementador pueda parar y verificar entre cada uno.

**Files:**
- Modify: `index.html` — insertar antes del marker `/* boot */`.

- [ ] **Step 1: Insertar el bloque JS antes del marker `/* boot */`**

Usar Edit con `old_string`:
```
/* boot */
state.authed=false;
```

y `new_string`:

```javascript
/* ────────── Chatbot IA Widget (F-Chatbot) ────────── */
const ChatWidget = (function(){
  const KEY = 'ceoadvisors_chat_history_v1';
  const MAX_MESSAGES = 50;
  const MAX_SCOPED_BYTES = 100_000;
  const ENDPOINT = SUPABASE_URL + '/functions/v1/chat-assistant';

  const state = {
    open: false,
    messages: [],
    loading: false,
    abortCtrl: null,
    unread: 0,
    streamingEl: null,
  };

  // ─── Persistencia localStorage ───
  function load(){
    try{
      const raw = localStorage.getItem(KEY);
      if(!raw) return;
      const parsed = JSON.parse(raw);
      if(Array.isArray(parsed)) state.messages = parsed.slice(-MAX_MESSAGES);
    }catch(e){ console.warn('[chat] load failed', e); }
  }
  function save(){
    try{
      if(state.messages.length > MAX_MESSAGES){
        state.messages = state.messages.slice(-MAX_MESSAGES);
      }
      localStorage.setItem(KEY, JSON.stringify(state.messages));
    }catch(e){ console.warn('[chat] save failed', e); }
  }
  function clearHistory(){
    state.messages = [];
    localStorage.removeItem(KEY);
    render();
  }

  // ─── Markdown parser inline (subset) ───
  function escapeHtml(s){
    return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  }
  function safeHref(url){
    return /^https?:\/\//i.test(url) ? url : '#';
  }
  function parseInline(text){
    // bold **x** → <b>, italic *x* → <i>, code `x` → <code>, link [t](u)
    let out = escapeHtml(text);
    out = out.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_, t, u) =>
      `<a href="${escapeHtml(safeHref(u))}" target="_blank" rel="noopener">${t}</a>`);
    out = out.replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>');
    out = out.replace(/(^|[^\*])\*([^*\n]+)\*/g, '$1<i>$2</i>');
    out = out.replace(/`([^`]+)`/g, '<code>$1</code>');
    return out;
  }
  function parseMarkdown(md){
    const lines = (md || '').split('\n');
    const out = [];
    let i = 0;
    while(i < lines.length){
      const line = lines[i];
      // Fenced code block
      if(/^```/.test(line)){
        const body = [];
        i++;
        while(i < lines.length && !/^```/.test(lines[i])){ body.push(escapeHtml(lines[i])); i++; }
        i++;
        out.push('<pre>'+body.join('\n')+'</pre>');
        continue;
      }
      // Table: header line + separator line
      if(/^\s*\|.+\|\s*$/.test(line) && i+1 < lines.length && /^\s*\|?[\s:|-]+\|?\s*$/.test(lines[i+1])){
        const headers = line.trim().replace(/^\||\|$/g,'').split('|').map(s=>s.trim());
        i += 2;
        const rows = [];
        while(i < lines.length && /^\s*\|.+\|\s*$/.test(lines[i])){
          rows.push(lines[i].trim().replace(/^\||\|$/g,'').split('|').map(s=>s.trim()));
          i++;
        }
        out.push('<table><thead><tr>'+headers.map(h=>'<th>'+parseInline(h)+'</th>').join('')+'</tr></thead><tbody>'+
          rows.map(r=>'<tr>'+r.map(c=>'<td>'+parseInline(c)+'</td>').join('')+'</tr>').join('')+'</tbody></table>');
        continue;
      }
      // List
      if(/^\s*[-*]\s+/.test(line) || /^\s*\d+\.\s+/.test(line)){
        const ordered = /^\s*\d+\.\s+/.test(line);
        const items = [];
        while(i < lines.length && (/^\s*[-*]\s+/.test(lines[i]) || /^\s*\d+\.\s+/.test(lines[i]))){
          items.push(lines[i].replace(/^\s*(?:[-*]|\d+\.)\s+/, ''));
          i++;
        }
        out.push('<'+(ordered?'ol':'ul')+'>'+items.map(it=>'<li>'+parseInline(it)+'</li>').join('')+'</'+(ordered?'ol':'ul')+'>');
        continue;
      }
      // Empty line
      if(line.trim()===''){ out.push(''); i++; continue; }
      // Paragraph
      out.push('<p>'+parseInline(line)+'</p>');
      i++;
    }
    return out.join('');
  }

  // ─── scopedData builder ───
  function buildScopedData(){
    if(typeof scopedDeals !== 'function') return {};
    const strip = arr => arr.map(o => {
      const c = {...o};
      delete c._supaId; delete c._supaUpdatedAt;
      return c;
    });
    const me = DB.currentUserId;
    let data = {
      deals: strip(scopedDeals()),
      clients: strip(scopedClients()),
      companies: strip(scopedCompanies()),
      activities: strip(scopedActivities()),
      pupilos: strip((DB.pupilos||[]).filter(p => p.mentor === me || isAdmin())),
      consultants: (DB.consultants||[]).map(c => ({code:c.id, name:c.name, role:c.role})),
    };
    // Truncate if oversized
    if(JSON.stringify(data).length > MAX_SCOPED_BYTES){
      const sortDesc = a => a.slice().sort((x,y) => (y.updatedAt||y.date||'').localeCompare(x.updatedAt||x.date||''));
      data = {
        deals: sortDesc(data.deals).slice(0,100),
        clients: sortDesc(data.clients).slice(0,50),
        companies: data.companies.slice(0,50),
        activities: sortDesc(data.activities).slice(0,30),
        pupilos: data.pupilos.slice(0,30),
        consultants: data.consultants,
        _truncated: true,
      };
    }
    return data;
  }

  // ─── Render ───
  function render(){
    const list = document.getElementById('chatMessages');
    if(!list) return;
    list.innerHTML = '';
    state.messages.forEach(m => {
      const div = document.createElement('div');
      div.className = 'chat-msg chat-msg-' + m.role;
      if(m.role === 'assistant'){
        div.innerHTML = parseMarkdown(m.content || '');
      }else{
        div.textContent = m.content;
      }
      list.appendChild(div);
    });
    list.scrollTop = list.scrollHeight;
    // Update FAB badge
    const badge = document.getElementById('chatFabBadge');
    if(badge){ badge.hidden = state.unread === 0; }
  }
  function appendStreaming(text){
    if(!state.streamingEl){
      const list = document.getElementById('chatMessages');
      const div = document.createElement('div');
      div.className = 'chat-msg chat-msg-assistant chat-cursor';
      list.appendChild(div);
      state.streamingEl = div;
    }
    state.streamingEl._buffer = (state.streamingEl._buffer || '') + text;
    state.streamingEl.innerHTML = parseMarkdown(state.streamingEl._buffer);
    const list = document.getElementById('chatMessages');
    list.scrollTop = list.scrollHeight;
  }
  function appendError(msg){
    const list = document.getElementById('chatMessages');
    const div = document.createElement('div');
    div.className = 'chat-msg-error';
    div.textContent = msg;
    list.appendChild(div);
    list.scrollTop = list.scrollHeight;
  }

  // ─── Send con SSE ───
  async function send(text){
    if(state.loading){ state.abortCtrl?.abort(); }
    if(!text.trim()) return;

    state.messages.push({role:'user', content:text});
    save();
    render();

    state.loading = true;
    state.streamingEl = null;
    state.abortCtrl = new AbortController();
    const sendBtn = document.getElementById('chatSend');
    if(sendBtn) sendBtn.disabled = true;

    try{
      const { data:{session} } = await sb.auth.getSession();
      if(!session){ throw new Error('NO_SESSION'); }

      const body = { messages: state.messages, scopedData: buildScopedData() };
      const res = await fetch(ENDPOINT, {
        method:'POST',
        headers:{
          'Content-Type':'application/json',
          'Authorization':'Bearer ' + session.access_token,
        },
        body: JSON.stringify(body),
        signal: state.abortCtrl.signal,
      });

      if(res.status === 401){ appendError('Tu sesión caducó. Recarga la página.'); return; }
      if(res.status === 429){
        const reset = res.headers.get('X-RateLimit-Reset');
        const min = reset ? Math.max(1, Math.ceil((parseInt(reset,10)*1000 - Date.now())/60000)) : '?';
        appendError(`Has alcanzado el límite de 30 mensajes/hora. Reintenta en ~${min} min.`);
        return;
      }
      if(!res.ok || !res.body){ appendError('Error del servidor. Reintenta más tarde.'); return; }

      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buf = '';
      let fullText = '';
      while(true){
        const { done, value } = await reader.read();
        if(done) break;
        buf += decoder.decode(value, {stream:true});
        let nl;
        while((nl = buf.indexOf('\n\n')) >= 0){
          const block = buf.slice(0, nl);
          buf = buf.slice(nl + 2);
          if(!block.startsWith('data: ')) continue;
          const payload = block.slice(6).trim();
          if(payload === '[DONE]') continue;
          try{
            const parsed = JSON.parse(payload);
            if(parsed.text){
              fullText += parsed.text;
              appendStreaming(parsed.text);
            }
            if(parsed.error){ appendError(parsed.error); }
          }catch{/* skip malformed */}
        }
      }
      if(fullText){
        state.messages.push({role:'assistant', content:fullText});
        save();
      }
    }catch(err){
      if(err.name === 'AbortError'){ /* silent */ }
      else if(err.message === 'NO_SESSION'){ appendError('No estás logueado. Recarga la página.'); }
      else{ appendError('Sin conexión. Reintenta.'); console.error('[chat]', err); }
    }finally{
      state.loading = false;
      state.abortCtrl = null;
      if(state.streamingEl){
        state.streamingEl.classList.remove('chat-cursor');
        state.streamingEl = null;
      }
      if(sendBtn) sendBtn.disabled = false;
      if(!state.open) state.unread++;
      render();
    }
  }

  // ─── Open/close ───
  function open(){
    state.open = true;
    state.unread = 0;
    document.getElementById('chatPopup').hidden = false;
    setTimeout(()=>document.getElementById('chatInput')?.focus(), 50);
    render();
  }
  function close(){
    state.open = false;
    document.getElementById('chatPopup').hidden = true;
  }
  function toggle(){ state.open ? close() : open(); }

  // ─── Wire-up DOM ───
  function init(){
    load();
    const fab = document.getElementById('chatFab');
    const popup = document.getElementById('chatPopup');
    if(!fab || !popup) return;

    fab.addEventListener('click', toggle);
    document.getElementById('chatClose').addEventListener('click', close);
    document.getElementById('chatClear').addEventListener('click', () => {
      if(confirm('¿Borrar el historial del chat?')) clearHistory();
    });

    const form = document.getElementById('chatForm');
    const input = document.getElementById('chatInput');
    form.addEventListener('submit', (e) => {
      e.preventDefault();
      const text = input.value;
      input.value = '';
      send(text);
    });
    input.addEventListener('keydown', (e) => {
      if(e.key === 'Enter' && !e.shiftKey){
        e.preventDefault();
        form.requestSubmit();
      }
      if(e.key === 'Escape'){ close(); }
    });
    render();
  }

  // Lazy init when the boot section runs (state.authed is wired later).
  // We expose init() and call it from boot.
  return { init, open, close, toggle, _state: state };
})();

/* boot */
state.authed=false;
```

- [ ] **Step 2: Llamar `ChatWidget.init()` desde el boot**

Editar el bloque boot (justo después de `render();` actual). Cambiar:

```javascript
state.authed=false;
state.view='today';
renderUserSwitcher();
render();
```

a:

```javascript
state.authed=false;
state.view='today';
renderUserSwitcher();
render();
try{ ChatWidget.init() }catch(e){ console.warn('chat init failed', e); }
```

- [ ] **Step 3: Verificar JS sintácticamente válido**

Extraer el contenido del último `<script>` ... `</script>` y pasarlo por `node --check`:

```python
python -c "
html=open('index.html', encoding='utf-8').read()
lines=html.split('\n')
s=next(i for i,l in enumerate(lines) if l.strip()=='<script>')
e=next(i for i in range(len(lines)-1,-1,-1) if lines[i].strip()=='</script>')
open('/tmp/check.js','w').write('\n'.join(lines[s+1:e]))
import subprocess
r=subprocess.run(['node','--check','/tmp/check.js'],capture_output=True,text=True)
print('OK' if r.returncode==0 else r.stderr[:400])
"
```

Expected: `OK`.

- [ ] **Step 4: Verificar fin del archivo**

```bash
tail -3 index.html
```

Expected: termina en `</html>`.

### Task 3.5: Smoke test del widget en navegador local

- [ ] **Step 1: Arrancar servidor estático**

```bash
python -m http.server 8000
```

Abrir `http://localhost:8000/index.html` en el navegador. Login con tus credenciales reales.

- [ ] **Step 2: Verificar burbuja visible**

Bottom-right debe aparecer una burbuja azul con 💬. Click → debe abrir popup ~400×520.

- [ ] **Step 3: Enviar mensaje "hola"**

Escribir "hola" en el textarea, Enter. Expected:
- Aparece burbuja azul derecha con "hola"
- Aparece burbuja gris izquierda con cursor parpadeante
- En <3s, llega stream de tokens y se rellena la respuesta
- Cursor desaparece al acabar

- [ ] **Step 4: Probar Cerrar mid-stream**

Mandar pregunta larga ("Explícame en detalle el flujo de Supabase del CRM"). Mid-respuesta, click ✕. Expected: popup cierra, no hay errores en consola. Reabrir: el último mensaje del asistente está truncado pero no crashea.

- [ ] **Step 5: Probar Borrar historial**

Click 🗑 → confirm dialog → confirm. Expected: chat vacío. Recargar página. Historial sigue vacío.

- [ ] **Step 6: Probar persistencia**

Enviar 2 mensajes. Cerrar popup. Recargar página. Click FAB. Expected: los 2 mensajes siguen ahí.

### Task 3.6: Commit del cliente

- [ ] **Step 1: Verificar `git status`**

```bash
git status
```

Expected: solo `index.html` modificado.

- [ ] **Step 2: Commit**

```bash
git add index.html
git commit -m "F-Chatbot 3/N: widget cliente en index.html

ChatWidget IIFE con burbuja flotante + popup, persistencia localStorage,
parser markdown inline con sanitizacion XSS, SSE stream reader, abort
y manejo de errores. Inicializado desde boot section.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Phase 4 — Matriz de testing manual

### Task 4.1: Ejecutar la matriz de tests del spec

Para cada escenario, marca el checkbox cuando pase. Si algo falla, abrir issue y NO desplegar.

- [ ] **Smoke:** Click FAB → escribir "hola" → respuesta en <3s ✓
- [ ] **Datos scoped:** "¿Cuántos deals abiertos tengo?" → número coincide con Pipeline ✓
- [ ] **Filtro complejo:** "Clientes Tier 1 sin actividad este mes" → tabla bien formateada ✓
- [ ] **Persistencia:** recargar página → historial conservado ✓
- [ ] **Borrar:** 🗑 + recargar → vacío ✓
- [ ] **Rate limit:** Mandar 31 msgs en una hora → msg 31 muestra "30 msg/hora alcanzado" ✓
  - Atajo recomendado: bajar `CHAT_RATE_LIMIT_MAX=3` con `supabase secrets set CHAT_RATE_LIMIT_MAX=3 && supabase functions deploy chat-assistant`. Mandar 4 msgs. El 4º debe devolver 429. Restaurar `CHAT_RATE_LIMIT_MAX=30` después.
- [ ] **Sin internet:** desconectar Wi-Fi → mandar → "Sin conexión" ✓
- [ ] **Abort:** pregunta larga + cerrar popup mid-stream → no crash ✓
- [ ] **Sanitización XSS:** pedir "muéstrame `<script>alert(1)</script>`" → texto plano, no ejecuta ✓
- [ ] **Concurrencia:** 2 mensajes rápidos → solo el último vivo ✓
- [ ] **L2 boundary:** "Crea un deal con ACME por $50k" → respuesta "Esa acción no está disponible aún…" ✓

### Task 4.2: Push a Railway (producción)

- [ ] **Step 1: Verificar branch**

```bash
git status
git log --oneline -5
```

Expected: en `main`, con los 3 commits de F-Chatbot.

- [ ] **Step 2: Push**

```bash
git push origin main
```

Expected: Railway detecta el push y empieza redeploy. Ver en dashboard de Railway.

- [ ] **Step 3: Esperar redeploy (~1 min)**

Visitar `https://ceo-advisors-crm-production.up.railway.app` y refrescar hasta ver la burbuja.

### Task 4.3: Smoke en producción

- [ ] **Step 1: Login en producción**

Login con tu cuenta real en `https://ceo-advisors-crm-production.up.railway.app`.

- [ ] **Step 2: Repetir tests críticos**

- Smoke (hola)
- Datos scoped (¿cuántos deals abiertos?)
- L2 boundary (intentar acción de escritura)

- [ ] **Step 3: Revisar logs**

```bash
supabase functions logs chat-assistant --tail
```

Expected: ninguna línea con `_error`. Token usage normal.

---

## Phase 5 — Documentación

### Task 5.1: Actualizar `CLAUDE.md`

**Files:**
- Modify: `CEO Advisors CRM/CLAUDE.md`

- [ ] **Step 1: Añadir sección sobre el chatbot en la sección "Arquitectura mental"**

Insertar como nuevo párrafo bajo "Arquitectura mental", después del párrafo de Realtime:

```markdown
**Chatbot IA L2 (F-Chatbot):** Widget burbuja flotante en `index.html` (`ChatWidget` IIFE antes de `/* boot */`). Persistencia historial en localStorage (`ceoadvisors_chat_history_v1`, cap 50 msgs). Backend: edge function `supabase/functions/chat-assistant/index.ts` (Deno) que custodia `ANTHROPIC_API_KEY` como secret, verifica JWT, aplica rate limit via RPC `chat_rate_limit_check` (30/h/user), construye system prompt con `cache_control: ephemeral` sobre instrucciones+scopedData, y hace SSE relay desde Anthropic Messages API (sonnet-4-6). Cliente envía `{messages, scopedData}` donde `scopedData` se construye con los helpers `scopedDeals/Clients/Companies/Activities` ya existentes. Read-only (L2): si el usuario pide acción de escritura, Claude la rechaza educadamente.
```

- [ ] **Step 2: Añadir sección "Pendientes razonables" con cosas no incluidas**

Modificar la sección final "Pendientes razonables (F15.5+ si Pablo lo pide)" para añadir:

```markdown
- Chatbot L3 (acciones de escritura via tool use con confirmación humana)
- Persistencia de conversaciones del chat en Supabase (cross-device)
- Logging de tokens consumidos por usuario para visibilidad de coste
- Chips de sugerencias rápidas en el chat
```

- [ ] **Step 3: Commit final**

```bash
git add CLAUDE.md
git commit -m "F-Chatbot 4/N: docs CLAUDE.md actualizada

Anadida seccion sobre chatbot IA L2 (widget cliente + edge function
+ rate limit RPC) y pendientes razonables (L3, cross-device, etc).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
git push origin main
```

---

## Verificación end-to-end final (gate de "done")

Marca todos al final:

- [ ] Edge function responde 200 a curl con JWT válido
- [ ] Edge function rechaza 401 sin JWT
- [ ] Edge function rechaza 429 al msg 31 en una hora
- [ ] Burbuja aparece bottom-right en todas las vistas del CRM
- [ ] Click FAB abre popup; click ✕ lo cierra
- [ ] Enviar "hola" devuelve stream visible en <3s
- [ ] Preguntar "¿Cuántos deals abiertos tengo?" devuelve número correcto
- [ ] Cerrar popup mid-stream no crashea
- [ ] Recargar página preserva historial
- [ ] Click 🗑 borra historial
- [ ] L3 prompt (acción de escritura) recibe rechazo educado
- [ ] HTML peligroso en respuesta no se ejecuta como código
- [ ] CLAUDE.md actualizada
- [ ] 4 commits en `main` (`F-Chatbot 1/4` … `4/4`) y pusheados a Railway

---

## Notas para el implementador

- **Cuidado con el comillado** al insertar el bloque JS grande con Edit: usar el patrón con marker `/* boot */` para garantizar inserción en posición correcta. Si Edit falla por unicidad, leer las 20 líneas alrededor del marker y ajustar `old_string` para incluir más contexto.
- **Si `node --check` falla** después de insertar el bloque JS: el archivo puede haber quedado mal cortado. Restaurar con `git checkout index.html` y re-aplicar con un batch script Python en vez de Edit (patrón documentado en `CEO Advisors CRM/CLAUDE.md` sección "Batch script Python para 3+ ediciones HTML"). Usar template literals JS con backticks para escapar `${...}` desde el Python triple-string.
- **El secret `ANTHROPIC_API_KEY` NUNCA se commitea.** Solo se setea via `supabase secrets set`.
- **No saltar Task 0.1.** Los cambios uncommitted en `index.html` y la migration 010 deben resolverse ANTES de empezar Phase 3. Si Phase 3 intenta editar `index.html` con un diff pendiente raro, los markers de Edit pueden romperse.
- **Si el rate limit a 30/h se queda corto en pruebas:** subir temporalmente con `supabase secrets set CHAT_RATE_LIMIT_MAX=999` y re-deploy. Bajar a 30 antes de cerrar el batch.
