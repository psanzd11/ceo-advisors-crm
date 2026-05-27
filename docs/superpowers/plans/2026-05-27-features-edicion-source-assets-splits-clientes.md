# Plan F16 — Edición clientes/empresas, Source of Contact, Digital Assets, Splits con clientes

**Fecha:** 2026-05-27
**Autor:** Claude + Pablo
**Estado:** Aprobado por Pablo, pendiente de ejecución

## Decisiones aprobadas (AskUserQuestion)

| Pregunta | Respuesta |
|---|---|
| Splits con clientes | **Atribución real de revenue** (cliente se lleva %, modelo unificado) |
| Digital Assets storage | **Supabase Storage** |
| Source of Contact en empresas | **Consultor o Cliente, exclusivo** |
| Orden de implementación | **C → B → A → D** |

## Fase 1 — Edición de clientes y empresas (F16.1)

**Cambios mínimos, cero migration.**

`openClient` (línea 5250) y `openCompany` (línea 5294) hoy renderizan `<div class="v">` read-only. Plan:

- Añadir botón "✎ Editar" en `drawerHd` junto al cierre.
- Click → conmuta `drawerBody` a un form (estilo `openNew('client')` que ya existe).
- Validación: nombre requerido, email regex si aplica, netWorth numérico ≥0.
- Guardar → `saveClient(c)` / `saveCompany(co)` con `updated_at = nowIso` → flush automático Supabase.
- Audit log automático vía hooks existentes.
- Cancel → restaura el view mode sin cambios.

**Estado actual:** sin patch.

## Fase 2 — Source of Contact en empresas (F16.2)

**1 migration ALTER TABLE.**

Esquema nuevo en `companies`:
- `source_type` text CHECK IN ('consultant','client','other',null)
- `source_ref` uuid (nullable, FK a `consultants.id` o `clients.id` según `source_type`)
- `source_note` text (libre)

Cliente (`index.html`):
- Mapping en `fetchFromSupabase` y `_supaToRow`.
- Form de empresa: dropdown tipo + selector de entidad cuando type∈{consultant,client}, o text input cuando type='other'.
- Vista drawer: campo "Source" con link clickable a la entidad.

Migration: `supabase_migrations/010_source_of_contact.sql`.

## Fase 3 — Digital Assets (F16.3)

**Nueva tabla + nuevo bucket Storage + nueva vista.**

Schema nuevo `digital_assets`:
- `id` uuid PK
- `code` text unique (formato `da1`, `da2`…)
- `name` text NOT NULL
- `type` text CHECK IN ('material','presentacion','lectura','guia')
- `file_path` text (path en bucket `digital-assets`)
- `file_size_bytes` bigint
- `mime_type` text
- `description` text
- `tags` text[]
- `created_by` uuid REFERENCES consultants(id)
- `created_at`, `updated_at` timestamptz
- `is_demo` boolean default false

Bucket Storage `digital-assets` (private, signed URLs 1h).

RLS:
- SELECT: todos los autenticados.
- INSERT/UPDATE: el propio uploader o admin.
- DELETE: solo admin.

Cliente:
- Nuevo `state.view='assets'` y entrada sidebar.
- 4 sub-tabs (material/presentación/lectura/guía).
- Upload: input file → sube a Storage (`sb.storage.from('digital-assets').upload`) + crea fila.
- Card view: thumb genérica por type + nombre + descripción + tags + uploader.
- Click → drawer con metadata + link "Descargar" (signed URL on demand).
- Filtros: type, tag, q.

Migration: `supabase_migrations/011_digital_assets.sql`.

## Fase 4 — Splits con clientes (F16.4) — INVASIVA

**Modelo unificado en `deals.splits`.**

Hoy: `splits: [{u: consultantId, pct}]`.
Nuevo: `splits: [{kind: 'u'|'c', id: uuid, pct}]`.

Backward-compat en `fetchFromSupabase`: si una row legacy trae `{u, pct}`, se transforma a `{kind:'u', id:u, pct}`. Al escribir, siempre el formato nuevo.

**Sitios que hay que tocar (~15):**

| Sitio | Cambio |
|---|---|
| `_rawScopedDeals` | `(d.splits||[]).some(sp=>sp.kind==='u'&&sp.id===DB.currentUserId)` |
| `splitAvatars` | Resolver `findConsultant` o `findClient` según kind |
| `_supaToRow` deals | Serializar el array con kind |
| `fetchFromSupabase` deals | Migrar legacy + resolver UUID por kind |
| Dashboards (líneas ~3594, 3616, 3721, 3723) | Iterar solo `kind==='u'` para credit a consultores, añadir bloque opcional "credit a clientes" |
| RLS policy deals | Función nueva `my_consultant_id_in_splits()` que filtra por kind |
| Filtro `consFilter` en deals view (2647, 2699) | Idem |
| Form deal (selector splits) | Permitir mix de consultores y clientes |
| Notifications (1834) | Notificar solo a `kind==='u'` |
| Migración export JSON | Defensa para no exportar PII de clientes con splits |

**RLS:** un cliente NO autentica en el CRM (solo consultores). Pero RLS debe permitir que un consultor vea/edite un deal donde haya un cliente en splits. Política actual: `EXISTS (SELECT 1 FROM unnest(splits) sp WHERE (sp).u = my_consultant_id())`. Nueva: `EXISTS (... WHERE (sp).kind='u' AND (sp).id = my_consultant_id())`.

**Migration:** `012_splits_with_clients.sql` — convierte el array existente en JSONB legacy a JSONB con kind. RPC `upsert_deals_if_newer` actualizado para validar el nuevo schema.

**Riesgos:**
- Si rompo el filtro RLS, consultores ven deals que no son suyos → confidencialidad.
- Backward-compat mal hecha = corrupción del array splits.
- Cálculos de pipeline/won credit dejan de cuadrar.

**Mitigación:** snapshot de tests manuales antes/después: pipeline total, won total, top consultor. Si difieren, rollback.

## Orden y estimación

| Fase | Esfuerzo | Migration | Riesgo |
|---|---|---|---|
| F16.1 Edición clientes/empresas | ~2-3 h | No | Bajo |
| F16.2 Source of contact | ~2 h | 1 ALTER | Bajo |
| F16.3 Digital Assets | ~4-5 h | 1 nueva tabla + bucket | Medio |
| F16.4 Splits con clientes | ~5-6 h | 1 transformación de JSONB | **Alto** |

Cada fase se commitea y deploya independientemente. F16.4 se hace en una sesión dedicada con tests.

## Lo que NO hace este plan

- No migra los datos seed (`is_demo=true`) para añadir source de empresas — quedará vacío en demo.
- No añade thumbnails reales para Digital Assets (sólo iconos por tipo).
- No permite splits con clientes de OTROS consultores (un cliente solo puede ir al split de un deal donde el consultor que lo registra ya esté).
- F16.4 no añade "share of revenue" en dashboards orientado a clientes (eso sería F16.5).
