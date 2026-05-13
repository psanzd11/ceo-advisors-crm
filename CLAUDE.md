# CLAUDE.md

Guía para Claude trabajando en CEO Advisors CRM. Solo lo esencial.

## Qué es el proyecto

CRM single-file (HTML + inline CSS/JS, vanilla, sin build) para gestionar clientes/empresas/deals/actividades/pupilos del equipo de CEO Advisors. Online-first con Supabase como backend; localStorage es cache de arranque. Hosted en Railway (`https://ceo-advisors-crm-production.up.railway.app`).

## Archivos clave

| Archivo | Rol |
|---|---|
| `index.html` | **Source único y deploy artifact.** ~7600 líneas, ~570KB. Lo que sirve Railway/Caddy. Editar aquí directamente |
| `Dockerfile` + `Caddyfile` + `railway.json` | Deploy config. Railway tira de `index.html` y lo sirve con Caddy en `$PORT` |
| `manifest.json` + `sw.js` | PWA básico |
| `migrate_to_supabase.py` | Importador one-shot Excel→Supabase (UUIDs deterministas via `uuid5`). Útil para re-importar si hace falta |
| `invite_remaining.py` | Reenvío de invitaciones Supabase Auth (rate-limited a ~2/hora con SMTP gratuito) |
| `supabase_migrations/*.sql` | Referencias de las migrations aplicadas (9 totales) |
| `supabase_migrations/.env.supabase` | URL + publishable key (públicas, no service_role) |
| `pupilo_docs/` | CVs de pupilos (datos reales, en .gitignore) |
| `limpieza/` | Archivos obsoletos del pipeline pre-Supabase (Excel template, `inject_data.py`, `sync.py`, `crm.bat`, source HTML separado, docs viejas). En .gitignore |

## Proyecto Supabase

- ID: `rtusnruywsmbbzejxooi` · Region us-west-1 · Postgres 17
- 7 tablas: `consultants/clients/companies/deals/activities/pupilos/activity_log` + `notifications`
- 2 helper functions: `is_admin()`, `my_consultant_id()` (SECURITY DEFINER, intencional)
- Auth: Supabase Auth (no hay PBKDF2 en el cliente)
- RLS activa en todas las tablas; modelo "yo edito lo mío" (admin todo, consultor edita deals donde está en `splits[].u`)
- Realtime en `deals/clients/activities/notifications`
- Credenciales públicas en `supabase_migrations/.env.supabase` (publishable key, no service_role)

## Arquitectura mental

**Mapeo bidireccional UUIDs ↔ códigos legacy:** Postgres usa UUIDs como id; el HTML conserva `code` (`u1`, `c1`, `d1`...) como id legacy en cliente, con UUID en `_supaId` por fila. Esto evitó refactor masivo de renderers. El mapeo se hace en `fetchFromSupabase` y se invierte en `_supaResolveUuid` en escritura.

**Storage adapter:** Toda lectura/escritura a localStorage pasa por `Storage = {read, write, clear}` (línea ~1047). Punto único de cambio si se sustituye el backend.

**Migrations versionadas en cadena:** `const MIGRATIONS = [{to: N, fn}]`. Se aplican si `d._schemaApplied < to`. Nunca modificar entradas existentes — añadir al final. Versión actual: `to:5` (purga campos legacy de password).

**Escritura a Supabase (F15.3d/4):** `saveDB()` → `scheduleSupabaseFlush()` con debounce 500ms → `flushSupabase()` computa diff vs `_supaSyncSnapshot` (key `ceoadvisors_supa_snapshot_v2`), envía vía RPCs `upsert_<tabla>_if_newer` (sólo aplica si server es más viejo), encola los rechazos en `ceoadvisors_supa_conflicts_v1` y dispara modal. Cola persistida en `ceoadvisors_supa_queue_v1` resiste recargas. Listener `online` reintenta.

**Realtime (F15.4e):** Tras refresh exitoso, `subscribeRealtime()` se conecta a 4 canales. `_supaHandleRealtime` filtra echo del propio cliente comparando signature contra el snapshot. Toast 2.8s muestra el cambio. `doLogout` desuscribe.

**Toggle "Ocultar demo" (F15.3e):** Wrappea los 4 helpers `scopedDeals/Clients/Activities/Companies` con un filtro `_notDemo`. Cero cambios en renderers porque todos pasan por scoped.

## Workflow del usuario

- **Día a día:** el equipo usa el CRM en `https://ceo-advisors-crm-production.up.railway.app`. Login con Supabase Auth (magic link o password). Los cambios se sincronizan automáticamente (debounce 500ms) y aparecen en otros dispositivos vía Realtime.
- **Cambio de código:** editar `index.html` → `git commit` + `git push` a `main` → Railway detecta y redeploya en ~1 min.
- **Cambios destructivos** (DDL, RLS, RPCs): nueva migration en `supabase_migrations/NNN_<name>.sql` y aplicar via MCP `apply_migration`.

## Cómo trabajar (lecciones destiladas)

**Antes de cualquier sesión, auditar (30 seg):**
```bash
tail -3 index.html                     # ¿termina en </html>?
# Verificar JS válido:
python3 -c "
import subprocess
html=open('index.html').read()
lines=html.split('\n')
s=next(i for i,l in enumerate(lines) if l.strip()=='<script>')
e=next(i for i in range(len(lines)-1,-1,-1) if lines[i].strip()=='</script>')
open('/tmp/c.js','w').write('\n'.join(lines[s+1:e]))
r=subprocess.run(['node','--check','/tmp/c.js'],capture_output=True,text=True)
print('OK' if r.returncode==0 else r.stderr[:300])
"
```

**Leer antes de planear.** Antes de añadir una feature, `Grep` por keywords y `Read` la función completa. Ha pasado varias veces que planeé "añadir X" y X ya existía (ej. mapa geográfico, stage history, métricas de pupilos). El plan inicial es incorrecto si se hace antes de leer.

**Reusar abstracciones existentes.** Helpers como `scopedDeals/scopedClients/scopedActivities` (filtran por consultor), `getStageProb`, `findSimilarName`, `Storage`, `MIGRATIONS` cubren la mayoría de necesidades. Antes de definir un helper nuevo, `grep` por patrones similares.

**Batch script Python para 3+ ediciones HTML.** Patrón validado:
```python
src = path.read_text(encoding="utf-8")
assert OLD in src, "marker X no encontrado"
src = src.replace(OLD, NEW, 1)   # count=1 SIEMPRE
# ... más replaces con assert ...
path.write_text(src, encoding="utf-8")
# Verify: node --check + tail + grep markers
```
Una pasada bien planeada equivale a ~10 Edits secuenciales en tokens.

**Backticks JS para escapar.** Cuando el batch Python genera código JS con `${...}`, usar template literals JS (backticks) dentro de Python triple-string. Cero conflicto con apóstrofes/comillas. **Esta es la solución definitiva al escape Python→JS.**

**Insertar antes de marker estable, nunca al final.** `/* boot */` y `/* ──────────── 2.1 Storage adapter` son markers que viven en posición temprana del archivo. Insertar funciones nuevas ANTES de ellos preserva el resto del archivo intacto.

**Verify completo tras cada batch** (no opcional):
1. `tail -3 index.html` — ¿termina en `</html>`?
2. `node --check` del JS extraído
3. Tail check: `state.authed=false` y `render();` presentes en últimos 1500 bytes
4. Grep de markers de cada feature añadida

**Si verify falla con archivo truncado** (síntoma: termina mid-statement como `ev.preventDefaul` o `if count == 0:` sin body):
```python
with open(f,'rb') as fh: data=fh.read()
trimmed = data[:data.rfind(b'\n')+1]
TAIL = b'''contenido conocido del final...'''
open(f,'wb').write(trimmed + TAIL)
```
Patrón usado 6 veces en este repo, fiable.

## Cómo presentar resultados a Pablo

- Respuesta concisa: **tabla resumen + 1 párrafo + links a archivos**. Nada de explicaciones largas tras entregar.
- Para fases grandes: plan upfront con riesgos y decisiones que necesitas; usa `AskUserQuestion` con opciones recomendadas; espera OK explícito; ejecuta.
- Retrospectiva breve después de cada fase: qué funcionó, qué fue ineficiente.
- Pablo prefiere español, iteración paso a paso, feedback visual. Optimizar tokens.

## Decisiones arquitectónicas a respetar

- **Auth en Supabase, no en el cliente.** El HTML ya no tiene `pbkdf2Hash/verifyPassword/setUserPassword`. Cambios de password vía `updateMyPassword` (`sb.auth.updateUser`). Admin reset vía `sendPasswordResetEmail` (`sb.auth.resetPasswordForEmail`).
- **`is_demo` flag.** Datos seed del Excel actual están marcados `is_demo=true`. Toggle UI los oculta. Cualquier fila creada por el CRM en runtime entra con `is_demo=false` (default).
- **RPC `upsert_<tabla>_if_newer`.** Reemplaza el upsert directo. Comportamiento actual = **last-write-wins**: el cliente envía siempre `updated_at: nowIso` (no `_supaUpdatedAt` viejo) → el RPC casi nunca rechaza en uso real. Modal de conflicto queda como salvaguarda residual.
- **`_supaUpdatedAt` por fila.** Se preserva en cliente solo para tracking de "qué versión vi por última vez", NO se envía como timestamp del upsert. Si haces "forzar", se bumpea `+60s` al futuro.
- **Realtime echo filter.** `_supaHandleRealtime` compara signature vs snapshot ANTES de aplicar. Si son iguales, es el propio echo del upsert anterior.

## Cosas que NUNCA romper

- **Idempotencia por `code`.** `migrate_to_supabase.py` usa UUIDs deterministas via `uuid5(NS_FIXED, code)` con `NS = UUID("00000000-0000-0000-0000-000000000001")`. Cambiar el NS = duplicar todo.
- **Filtro de passwords en export JSON** (`btnExport`) — defensa, aunque hoy no hay passwords.
- **IDs secuenciales.** `uid(prefix)` busca el siguiente número libre del prefijo en todas las entidades. Prefijos: `u` (consultants), `c` (clients), `co` (companies), `d` (deals), `a` (activities), `p` (pupilos), `au` (audit), `nt` (notifications).
- **`_seedTs` detection en `loadDB()`.** Pregunta al usuario antes de pisar localStorage.
- **Boot section completo:** `state.authed=false; state.view='today'; renderUserSwitcher(); render();` antes de `</script>`. Si falta `render();`, el CRM aparece roto.
- **Lockout login:** `LOCKOUT_LIMIT=5/LOCKOUT_MIN=15` en `ceoadvisors_login_fails_v1`.
- **Snapshot key versionada.** Hoy `ceoadvisors_supa_snapshot_v2`. Bumpear a v3 sólo si cambia el orden de propiedades de `_supaToRow` (JSON.stringify es orden-dependiente).
- **Migraciones DDL Postgres:** orden importa. 006 antes que 009 porque 009 referencia columnas que 006 crea.
- **Nombres RPC `upsert_<tabla>_if_newer`** hardcodeados en cliente. Renombrar = romper en silencio.
- **`_supaSignature` y `_supaToRow` deben ser deterministas y consistentes.** El filtro de echo Realtime depende de que la signature del payload entrante sea idéntica a la guardada en snapshot tras un upsert exitoso.
- **`is_admin()` y `my_consultant_id()`** referenciadas en todas las policies RLS. Cambio incompatible = todas las RLS rotas.
- **`gsSearch` cubre 6 tipos.** Si añades un 7º (org, contact, etc.), ampliar `gsSearch` y `gsSelect`.

## Comportamiento a evitar

- **No expandir scope para "completar un plan".** Si una feature ya existe, skip y reemplaza por algo cercano y útil (validado en F1, F6, F14).
- **No insertar código al final del archivo.** Vulnerabilidad a truncado. Usar markers tempranos.
- **No usar Edit con template literals JS largos cerca del final.** Vuelve a fallar (F10). Usar batch script con backticks.
- **No tocar `migrateAuth` para quitarla completa.** Hay 3 callsites; mantener como no-op defensivo.
- **No habilitar Realtime en `consultants/pupilos/companies/activity_log`** sin pensarlo — alto coste, baja frecuencia.
- **No actualizar snapshot fuera de `flushSupabase` exitoso o `refreshFromSupabaseIfPossible`.** Pierde el diff de cambios pendientes.

## Estado actual (post F15.4)

- ~52 features funcionales en el CRM.
- 9 migrations Postgres aplicadas (initial schema + harden + auto_link auth + harden trigger + is_demo + add_collab_fields + rls_collaborative + notifications_table + upsert_if_newer_rpcs).
- 8 consultants reales en Supabase, 136 filas totales (incluyendo demo).
- 2/8 invitaciones enviadas (rate limit SMTP gratuito Supabase ≈ 2/hora). Pendiente configurar SMTP custom (SendGrid/Resend) en Supabase Auth → settings.
- Advisors security: 6 WARNs cosméticos (citext en public, SECURITY DEFINER ejecutables, leaked password protection). 0 errores.

## Pendientes razonables (F15.5+ si Pablo lo pide)

- Column-level merge en conflict (hoy row-level).
- Audit local→Supabase retroactivo (hoy sólo prospectivo).
- Eliminar `_supaId` y usar `code` como id estable (refactor mayor; no urgente).
- Supabase Storage para `pupilo_docs/`.
- SMTP custom para invitaciones.
