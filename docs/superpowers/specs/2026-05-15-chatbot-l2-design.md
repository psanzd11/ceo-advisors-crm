# Chatbot IA (L2 — análisis sobre datos scoped) — Diseño

**Fecha:** 2026-05-15
**Estado:** Aprobado para implementación
**Tracking:** Reemplaza Fase D del plan `onboarding-datos-reales-y-chatbot.md`

## Resumen ejecutivo

Añadir un asistente IA al CEO Advisors CRM que responda preguntas analíticas sobre los datos del consultor logueado. Alcance Nivel 2: solo lectura, no acciones de escritura. UI tipo burbuja flotante con popup. Backend en Supabase Edge Function que custodia la API key de Anthropic y hace de relay SSE hacia el cliente.

**Estimación total:** ~12 horas de implementación, repartidas en 3 fases.

## Decisiones tomadas

| Decisión | Elección | Razón |
|---|---|---|
| Alcance | **L2** (análisis lectura, no escritura) | ROI real sin la superficie de riesgo de L3 (tool use con escritura) |
| API key | **Pablo personal**, swappable via env var | Piloto rápido; cambio futuro sin tocar código |
| UI | **Burbuja flotante + popup ~400×500px** | Estilo Intercom, no invade el flujo del CRM |
| Persistencia historial | **localStorage por sesión** | No requiere tabla nueva en Supabase; suficiente para popup compacto |
| Arquitectura de contexto | **Inline JSON dump** (Opción 1) | Volumen actual (~5-15k tokens/user) cabe sobrado; latencia mínima |
| Modelo | **claude-sonnet-4-6** | Capacidad analítica para L2; con prompt caching, coste razonable |
| Streaming | **SSE token-by-token** | UX conversacional moderna |
| Rate limit | **30 mensajes/hora/usuario** | Defensa contra abuso accidental; revisable según uso real |
| Markdown rendering | **Parser inline minimalista (~80 líneas, sin deps)** | Single-file CRM, no añadir 50kb de marked.js |

## Arquitectura

```
┌─────────────────────────────────┐
│  index.html  (cliente)          │
│  ┌───────────────────────────┐  │
│  │ Widget Chat (NUEVO)       │  │
│  │ - Burbuja flotante        │  │
│  │ - Popup 400×500           │  │
│  │ - Historial localStorage  │  │
│  │ - SSE stream renderer     │  │
│  │ - Parser markdown inline  │  │
│  └────────────┬──────────────┘  │
└───────────────┼─────────────────┘
                │ fetch POST /chat-assistant
                │ Authorization: Bearer <supabase JWT>
                │ Body: { messages, scopedData }
                ▼
┌─────────────────────────────────┐
│ Supabase Edge Function (NUEVO)  │
│ chat-assistant (Deno + TS)      │
│ - Verifica auth.uid()           │
│ - Rate limit 30/h/user (Deno KV)│
│ - Construye system prompt       │
│ - Stream a Anthropic            │
│ - Pipe SSE de vuelta al cliente │
└────────────┬────────────────────┘
             │ POST api.anthropic.com/v1/messages
             │ stream: true · cache_control en system
             ▼
┌─────────────────────────────────┐
│ Anthropic API                   │
│ claude-sonnet-4-6               │
│ Prompt caching activado         │
└─────────────────────────────────┘
```

### Boundaries

| Pieza | Responsabilidad única | Interfaz |
|---|---|---|
| Widget cliente | UI del chat, historial local, render SSE | Llama `POST /chat-assistant` con `{messages, scopedData}` → consume SSE |
| Edge Function | Auth + rate limit + prompt building + stream relay | Recibe `{messages, scopedData}` → devuelve SSE de tokens |
| Anthropic API | Generación | API estándar Messages con streaming |

### Por qué la edge function (no Anthropic directo desde cliente)

La API key de Anthropic NUNCA puede vivir en HTML público. La edge function la custodia como secret env var (`ANTHROPIC_API_KEY`). Beneficios adicionales: rate limit centralizado, swap de modelo/proveedor futuro sin tocar el cliente.

### Por qué `scopedData` se construye en el cliente

El cliente ya tiene todos los datos del usuario en memoria (`state.db`, filtrado vía RLS por Supabase). Pedir a la edge function que vuelva a consultar Supabase sería duplicar trabajo y latencia. La edge function confía en el JWT (es del usuario) y en RLS (los datos que pueda enviar son los que ya podía leer). No abre nuevo vector de ataque.

## Widget cliente (HTML/JS dentro de `index.html`)

### Ubicación en código

Bloque nuevo insertado **antes del marker `/* boot */`** (línea ~7400 actual). Cero impacto en el resto del archivo. Tipo de patrón ya validado por el equipo en features previas (F15.3, F15.4).

### Estructura HTML (3 nodos top-level, `position: fixed`)

```html
<button id="chatFab" aria-label="Asistente IA">💬</button>

<div id="chatPopup" hidden>
  <header>
    <h3>Asistente IA</h3>
    <button id="chatClear" title="Borrar historial">🗑</button>
    <button id="chatClose">✕</button>
  </header>
  <div id="chatMessages"></div>
  <form id="chatForm">
    <textarea id="chatInput" placeholder="Pregunta sobre tus deals, clientes…" rows="2"></textarea>
    <button type="submit" id="chatSend">↑</button>
  </form>
</div>
```

### CSS scoping

Todos los selectores bajo `#chatFab, #chatPopup`. `z-index: 9000` (debajo de modales en `9999`). Sigue tokens existentes: `--bg`, `--text`, `--accent`. No toca ninguna clase global.

### Estado JS (IIFE)

```js
const ChatWidget = (function(){
  const KEY = 'ceoadvisors_chat_history_v1';
  const RATE_LIMIT_MSG = 'Has alcanzado 30 mensajes/hora. Reintenta más tarde.';
  let state = {
    open: false,
    messages: [],   // [{role:'user'|'assistant', content:'...'}]
    loading: false,
    abortCtrl: null,
    unread: 0,      // badge en FAB si popup cerrado
  };
  // load(), save(), open(), close(), send(), abort(), render(), clear()
})();
```

### localStorage

- **Key:** `ceoadvisors_chat_history_v1` (versionada).
- Guardar tras cada mensaje completo (user msg + respuesta final).
- Tras cada `save()`, si `messages.length > 50`, truncar a los últimos 50 (~24 turnos).
- Borrar con botón 🗑 (vacía `messages` y `localStorage.removeItem(KEY)`).

### Construcción de `scopedData`

```js
function buildScopedData() {
  return {
    deals: scopedDeals().map(d => ({...d, _supaId:undefined, _supaUpdatedAt:undefined})),
    clients: scopedClients().map(c => ({...c, _supaId:undefined, _supaUpdatedAt:undefined})),
    companies: scopedCompanies().map(co => ({...co, _supaId:undefined, _supaUpdatedAt:undefined})),
    activities: scopedActivities().map(a => ({...a, _supaId:undefined, _supaUpdatedAt:undefined})),
    pupilos: state.db.pupilos
      .filter(p => p.mentor === state.currentUser || isAdmin())
      .map(p => ({...p, _supaId:undefined, _supaUpdatedAt:undefined})),
    consultants: state.db.consultants.map(c => ({code:c.code, name:c.name, role:c.role})),
  };
}
```

Si `JSON.stringify(scopedData).length > 100_000`, truncar a últimos 100 deals + 50 clientes + 30 actividades + 30 pupilos (ordenando por `updated_at` desc). Mostrar aviso inline en el chat: "Mostrando subset reciente de tus datos".

### Render de mensajes

- **User msg:** burbuja accent right-aligned, texto plano escapado.
- **Assistant msg:** burbuja neutral left-aligned, **markdown ligero** (parser propio).
- **Mientras streamea:** append progresivo de tokens al último bloque del asistente. Cursor parpadeante hasta `message_stop`.
- **Auto-scroll** al bottom siempre que no haya intervención manual.

### Atajos teclado

- `Enter` → enviar
- `Shift+Enter` → newline
- `Esc` (popup abierto) → cerrar

### Abort

Cerrar popup mid-stream o teclear nuevo mensaje con uno en vuelo → `state.abortCtrl.abort()` → mensaje truncado con `…` y nuevo turno arranca.

## Edge Function `chat-assistant`

### Archivo

`supabase/functions/chat-assistant/index.ts` (Deno + TypeScript)

### Secret env

`ANTHROPIC_API_KEY` — `supabase secrets set ANTHROPIC_API_KEY=sk-ant-...`

### Flujo del handler

1. **CORS preflight** (`OPTIONS`) → 200 con headers permisivos para `*.up.railway.app`.
2. **Auth:** parsear `Authorization: Bearer <jwt>`. Verificar con `supabase.auth.getUser(jwt)`. Si falla → **401**.
3. **Rate limit (Postgres RPC atómico):**
   - `hourBucket = Math.floor(Date.now() / 3600000)`
   - Llamar `rpc('chat_rate_limit_check', {p_user: userId, p_bucket: hourBucket, p_max: 30})`
   - El RPC hace `INSERT ... ON CONFLICT DO UPDATE SET count = count + 1 RETURNING count`
   - Si `count > 30` → RPC devuelve `{allowed: false, reset_at: <epoch_próximo_bucket>}` → handler responde **429** con header `X-RateLimit-Reset`
   - Else continúa.
   - Decisión por Postgres en vez de Deno KV: en Supabase Edge Functions, Deno KV no garantiza persistencia entre cold starts. Postgres ya está disponible vía el cliente Supabase y unifica con el patrón del resto del proyecto.
4. **Parse body:** `{ messages: ChatMessage[], scopedData: ScopedData }`. Validar:
   - `messages.length > 0` y `messages.length <= 60` (cap defensivo, cliente ya cappea a 50)
   - `messages[messages.length-1].role === 'user'`
   - `scopedData` es objeto JSON válido
   - **Defensa en profundidad de tamaño:** `Content-Length <= 200_000` (límite duro del body) **Y** `JSON.stringify(scopedData).length <= 100_000` (límite blando, cliente ya trunca antes de enviar; este check es por si el cliente envía algo inesperado).
   - Si falla → **400** con mensaje descriptivo
5. **Build prompt:**
   - **system block 1** (cacheable, `cache_control: {type:'ephemeral'}`): instrucciones del asistente (rol, tono, formato output, límites).
   - **system block 2** (cacheable): `scopedData` serializado.
   - **system block 3** (no-cache): metadata dinámica (currentDate, userName, userRole, currentUserCode).
   - **messages:** historial completo del cliente (último msg incluido).
6. **Llamada Anthropic:**
   ```
   POST https://api.anthropic.com/v1/messages
   model: 'claude-sonnet-4-6'
   max_tokens: 2048
   stream: true
   system: [block1, block2, block3]
   messages: [...]
   ```
7. **Stream relay:** leer ReadableStream de Anthropic, filtrar eventos `content_block_delta`, reenviar al cliente como SSE puro (`data: {text}\n\n`). Cerrar con `data: [DONE]\n\n`.
8. **Log:** si error >= 500, log a `console.error` (visible en `supabase functions logs`). No persistir en tabla por ahora.

### Migration para rate limit (Postgres)

Archivo: `supabase_migrations/011_chat_rate_limits.sql`

```sql
create table if not exists public.chat_rate_limits (
  user_id     uuid not null,
  hour_bucket integer not null,
  count       integer not null default 0,
  primary key (user_id, hour_bucket)
);

-- Limpieza automática de buckets viejos (cron diario opcional, no crítico)
create index if not exists chat_rate_limits_bucket_idx
  on public.chat_rate_limits (hour_bucket);

-- RLS: solo lectura/escritura desde el service role (la edge function la usa con
-- service role implícito vía supabase-js admin). El usuario final nunca toca la tabla.
alter table public.chat_rate_limits enable row level security;

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
```

### Construcción del system block 1 (instrucciones)

```
Eres el asistente IA del CEO Advisors CRM. El usuario es un consultor del equipo
que está consultando sus propios datos (deals, clientes, empresas, actividades,
pupilos a su cargo).

REGLAS:
- Responde SIEMPRE en español, salvo que el usuario use otro idioma.
- Tu rol es analizar y explicar los datos del usuario, no proponer cambios ni
  ejecutar acciones. Si te piden crear/editar/borrar algo, responde:
  "Esa acción no está disponible aún. Hazlo desde el CRM directamente."
- Cuando muestres listas de >3 items, usa una tabla markdown.
- Sé conciso: respuestas de <120 palabras salvo que el análisis lo requiera.
- Si la pregunta no es sobre el CRM, redirige amablemente: "Puedo ayudarte con
  análisis sobre tus deals, clientes, empresas, actividades y pupilos."
- Las fechas de los datos son ISO (YYYY-MM-DD).
- 'splits' en deals indica cómo se reparte la atribución entre consultores.
- 'is_demo: true' indica dato de demo, generalmente irrelevante para análisis real.

FORMATO:
- Markdown ligero: **negrita**, listas, tablas, `code`.
- NUNCA HTML directo.
- Si hay ambigüedad en la pregunta, pide una aclaración antes de responder.
```

### Tamaño y coste

- Static block 1: ~600 tokens
- scopedData típico: ~5-15k tokens
- Historial reciente: ~2-5k tokens
- **Total ~10-25k tokens/turno** · con caching → ~3-8k tokens nuevos/turno
- Sonnet 4.6: $3/MTok input, $0.30/MTok cached read, $15/MTok output
- Conversación 5 turnos ≈ $0.05
- 8 consultores × 20 turnos/día × $0.05 = ~$8/día worst case · realista $1-3/día

## Markdown rendering (cliente)

Parser inline, ~80 líneas JS, soporta:

- `**negrita**`, `*itálica*`
- Listas `-`, `1.`
- Tablas `| col | col |` (con `|---|---|`)
- `code inline` y bloques ``` ``` ```
- Links `[text](url)` con check `^https?://`

**Sanitización:** salida pasa por whitelist de tags (`b, i, ul, ol, li, table, thead, tbody, tr, td, th, code, pre, a, p, br`). Atributos solo `href` con check `http(s):`. Sin `<script>`, `<style>`, `<iframe>`, ni event handlers inline.

## Data flow end-to-end (un turno)

```
[Usuario teclea en input] → Enter
   ↓
ChatWidget.send():
   - state.messages.push({role:'user', content})
   - render() pinta msg user + placeholder asistente vacío
   - localStorage.save()
   - scopedData = buildScopedData()
   - state.abortCtrl = new AbortController()
   - fetch('https://<proj>.supabase.co/functions/v1/chat-assistant', POST,
           Authorization: Bearer <sb.auth.session.access_token>,
           body: JSON.stringify({messages: state.messages, scopedData}),
           signal: state.abortCtrl.signal)
   ↓
Edge function recibe → valida JWT → rate limit OK → build prompt → stream Anthropic
   ↓
Cada chunk SSE de Anthropic (filtrado a 'content_block_delta') reenviado al cliente como 'data: {text}\n\n'
   ↓
Cliente lee el ReadableStream:
   for await (chunk of reader) → append a último msg asistente → render incremental
   ↓
Stream termina con 'data: [DONE]'
   ↓
   - state.messages.push({role:'assistant', content: <texto completo>})
   - localStorage.save()
   - render() finaliza (quita cursor parpadeante)
   - si popup cerrado → state.unread++ → badge rojo en FAB
```

## Error handling

| Caso | Detección | UX |
|---|---|---|
| Sin conexión | `fetch` lanza `TypeError` | Mensaje rojo inline "Sin conexión" + botón Reintentar |
| 401 sesión caducada | Status 401 | "Tu sesión caducó, recarga la página"; trigger `doLogout()` |
| 429 rate limit | Status 429 | "30 msg/hora alcanzado. Reintenta en X min" (X de header `X-RateLimit-Reset`) |
| 500 edge function | Status 5xx | "Error del servidor. Reportar si persiste." + Reintentar |
| Anthropic timeout | Edge function 504 | Mismo que 500 |
| Abort por usuario | AbortController | Silencioso, mensaje truncado con `…` |
| scopedData > 100KB | Validación cliente | Truncar + aviso "Mostrando subset reciente de tus datos" |
| Respuesta sin contenido | Stream termina sin tokens | "No pude generar respuesta, reintenta" |
| Doble envío rápido | Detección `state.loading` | Abortar primero, lanzar nuevo |

## Testing manual (no hay test framework en el repo)

| Escenario | Pasos | Resultado esperado |
|---|---|---|
| Smoke | Abrir CRM, click FAB, escribir "hola" | Stream de respuesta en <3s |
| Datos scoped | "¿Cuántos deals abiertos tengo?" | Número coincide con vista Pipeline |
| Filtro complejo | "Clientes Tier 1 sin actividad este mes" | Lista correcta, tabla bien formateada |
| Persistencia | Recargar página con popup cerrado | Historial sigue al reabrir |
| Borrar | Click 🗑 + recargar | Historial vacío |
| Rate limit | Mandar 31 msgs en <1h | Msg 31 muestra 429 |
| Sin internet | Desconectar Wi-Fi | "Sin conexión" + retry |
| Abort | Pregunta larga + cerrar popup mid-stream | No crash, no doble respuesta al reabrir |
| Sanitización | Pedir "muéstrame `<script>alert(1)</script>`" | Renderiza como texto, no ejecuta |
| Concurrencia | 2 mensajes rápidos | Solo el último vivo |
| L2 boundary | "Crea un deal con ACME por $50k" | Respuesta: "Esa acción no está disponible aún…" |

**Pre-deploy edge function:** `supabase functions serve chat-assistant` + curl con un JWT real.

## Phasing de implementación

### Fase 1 — Edge function + migration (~4.5h)
1. Crear y aplicar migration `011_chat_rate_limits.sql` via MCP `apply_migration`
2. `supabase functions new chat-assistant`
3. Implementar handler completo (auth, rate limit RPC, prompt, stream relay)
4. `supabase functions serve` + curl test con JWT real
5. `supabase secrets set ANTHROPIC_API_KEY=...`
6. `supabase functions deploy chat-assistant`
7. Smoke remoto con curl al endpoint deployado

### Fase 2 — Widget cliente (~6h)
1. Insertar HTML + CSS antes de `/* boot */` en `index.html`
2. Implementar `ChatWidget` IIFE (state, render, send, abort, clear)
3. Parser markdown inline + sanitización
4. localStorage handling
5. `node --check` del JS extraído del index.html
6. Smoke en navegador local

### Fase 3 — Integración y deploy (~2h)
1. Pruebas matriz de Testing (todos los casos)
2. Commit + push → Railway redeploy
3. Verificación post-deploy con cuenta de Pablo en producción

**Total: ~12 horas.**

## Cosas que NO están en este batch (explícitamente)

- L3 / acciones de escritura via tool use (crear deal, editar cliente)
- Persistencia de conversaciones cross-device (tabla Supabase)
- Voice input / speech-to-text
- Sugerencias rápidas tipo chips ("Mis deals esta semana")
- Charts/gráficos (solo tablas markdown)
- Multi-idioma (responde en español por defecto)
- Logging detallado de conversaciones a Supabase
- Telemetría de uso
- Onboarding de Santiago (movido a lunes 2026-05-18)

## Riesgos y mitigaciones

| Riesgo | Mitigación |
|---|---|
| Coste API se dispara si un usuario abusa | Rate limit 30/h. Logging de tokens por turno (futuro). |
| Anthropic API outage | UX clara "Servidor caído, reintenta". No degrada el CRM principal. |
| Edge function cold start (~500ms) | Aceptable para un primer turno; subsequent turns son cálidos. |
| scopedData masivo en consultores con muchos deals | Truncar a 100/50/30 si excede 100KB. |
| User filtra info confidencial vía chatbot a Claude | Anthropic NO entrena con datos API. Documentar en política interna. |
| Markdown parser tiene bug XSS | Whitelist agresiva de tags + check de `href` strict. Sin atributos arbitrarios. |
| Token caching no funciona como esperado | Telemetría manual en primeros días para validar (revisar Anthropic dashboard). |

## Cambiable en el futuro sin tocar código

- **API key:** `supabase secrets set ANTHROPIC_API_KEY=...`
- **Modelo:** variable en edge function (`MODEL = Deno.env.get('CLAUDE_MODEL') ?? 'claude-sonnet-4-6'`)
- **Rate limit:** constante en edge function (rebuild función pero no tocar cliente)
- **Instrucciones del asistente:** strings en edge function

## Archivos a crear/modificar

| Archivo | Acción |
|---|---|
| `supabase/functions/chat-assistant/index.ts` | **Crear** |
| `supabase/functions/chat-assistant/deno.json` | **Crear** (imports map) |
| `supabase_migrations/011_chat_rate_limits.sql` | **Crear** (table + RPC `chat_rate_limit_check`) |
| `index.html` | **Modificar** (insertar widget antes de `/* boot */`) |
| `CLAUDE.md` | Añadir sección breve sobre chatbot post-deploy |

## Verificación end-to-end (gate de "done")

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
