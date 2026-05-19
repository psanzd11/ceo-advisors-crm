# Clientes y empresas como libreta compartida — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminar el filtrado de `clients` y `companies` por deals propios — convertir ambas tablas en libreta compartida del equipo (todos ven todo, todos pueden crear/editar, solo admin/CEO borra).

**Architecture:** Dos cambios mínimos: (1) migración Postgres que abre las policies RLS de `clients`/`companies` a `authenticated` para INSERT/UPDATE manteniendo DELETE admin-only; (2) ajuste de los helpers `_rawScopedClients` y `_rawScopedCompanies` en `index.html` para devolver la colección completa en vez de filtrar por deals del usuario.

**Tech Stack:** Postgres 17 (Supabase) + RLS policies, vanilla JS embebido en `index.html`. Sin build, sin tests automatizados — verificación es manual y vía MCP `execute_sql`.

**Spec:** `docs/superpowers/specs/2026-05-19-clientes-empresas-libreta-compartida-design.md`

---

## Pre-flight: auditoría inicial (obligatoria antes de empezar)

- [ ] **Step P1: Verificar que el HTML está sano y el JS parsea**

Run (PowerShell):
```powershell
$html = Get-Content "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html" -Raw
$lines = $html -split "`n"
$s = 0; for($i=0; $i -lt $lines.Length; $i++){ if($lines[$i].Trim() -eq '<script>'){ $s=$i; break } }
$e = 0; for($i=$lines.Length-1; $i -ge 0; $i--){ if($lines[$i].Trim() -eq '</script>'){ $e=$i; break } }
$lines[($s+1)..($e-1)] -join "`n" | Out-File "$env:TEMP\check.js" -Encoding utf8
node --check "$env:TEMP\check.js"
```
Expected: sin output (parseo OK). Si imprime error, parar y arreglar antes de continuar.

- [ ] **Step P2: Confirmar el estado actual de las RLS en Supabase**

Usar MCP tool `mcp__claude_ai_Supabase__execute_sql` con project_id `rtusnruywsmbbzejxooi`:
```sql
select policyname, cmd, qual::text, with_check::text
from pg_policies
where schemaname='public' and tablename in ('clients','companies')
order by tablename, cmd;
```
Expected: ver `"clients select all auth"`, `"clients write admin"`, `"companies select all auth"`, `"companies write admin"`. Si no existen exactamente con esos nombres, parar y reconciliar el plan con la realidad (otra migración ya tocó las policies).

- [ ] **Step P3: Confirmar la línea exacta de los helpers a modificar**

Run:
```powershell
Select-String -Path "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html" -Pattern "^const _rawScopedClients" -SimpleMatch:$false
Select-String -Path "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html" -Pattern "^const _rawScopedCompanies" -SimpleMatch:$false
```
Expected: una sola coincidencia para cada uno alrededor de la línea 1962-1964. Si hay 0 o >1 coincidencias, parar.

---

## File Structure

**Crear:**
- `supabase_migrations/013_clients_companies_shared.sql` — DDL declarativo de las nuevas policies, registrado en repo como historia auditable.

**Modificar:**
- `index.html` líneas ~1962-1965 — los helpers `_rawScopedClients` y `_rawScopedCompanies`.

**No tocar:**
- `_rawScopedActivities` (sigue usando `scopedClientIdSet`/`scopedCompanyIdSet`).
- `_rawScopedDeals` (sin cambio — los deals siguen siendo "míos" via splits).
- Cualquier RPC `upsert_*_if_newer`.
- Triggers, indexes, otras tablas.

**Nota sobre el borrado UI:** se auditó (`Grep`) y no existe botón "Eliminar cliente/empresa" en `index.html`. El spec menciona añadir un guard, pero al no haber UI de borrado para clients/companies, **no aplica**. Si en el futuro se añade UI de borrar, se gating por `isAdmin()` allí. No es parte de este plan.

---

## Task 1: Crear migration SQL

**Files:**
- Create: `supabase_migrations/013_clients_companies_shared.sql`

- [ ] **Step 1: Escribir el archivo de migración**

Crear `supabase_migrations/013_clients_companies_shared.sql` con este contenido exacto:

```sql
-- F-LibretaCompartida (2026-05-19)
-- Convierte clients y companies en libreta compartida: cualquier autenticado
-- puede INSERT/UPDATE. DELETE sigue restringido a admin/CEO.
-- Mantiene SELECT abierto a authenticated (sin cambio respecto a 001).

-- ─── clients ────────────────────────────────────────────────────
drop policy if exists "clients write admin" on public.clients;

create policy "clients insert auth" on public.clients
  for insert to authenticated
  with check (auth.uid() is not null);

create policy "clients update auth" on public.clients
  for update to authenticated
  using (auth.uid() is not null)
  with check (auth.uid() is not null);

create policy "clients delete admin" on public.clients
  for delete to authenticated
  using (public.is_admin());

-- ─── companies ──────────────────────────────────────────────────
drop policy if exists "companies write admin" on public.companies;

create policy "companies insert auth" on public.companies
  for insert to authenticated
  with check (auth.uid() is not null);

create policy "companies update auth" on public.companies
  for update to authenticated
  using (auth.uid() is not null)
  with check (auth.uid() is not null);

create policy "companies delete admin" on public.companies
  for delete to authenticated
  using (public.is_admin());
```

- [ ] **Step 2: Verificar formato y contenido**

Run:
```powershell
Get-Content "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\supabase_migrations\013_clients_companies_shared.sql" | Measure-Object -Line
```
Expected: 33 líneas aprox.

```powershell
Select-String -Path "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\supabase_migrations\013_clients_companies_shared.sql" -Pattern "drop policy if exists" | Measure-Object
```
Expected: Count = 2.

- [ ] **Step 3: NO commitear todavía** — el commit junta el archivo, la migración aplicada vía MCP y los cambios del JS al final del plan, para que un revert sea atómico.

---

## Task 2: Aplicar migration vía MCP

**Files:**
- Ningún cambio en filesystem en esta tarea. Cambio en proyecto Supabase remoto.

- [ ] **Step 1: Aplicar la migración**

Usar MCP tool `mcp__claude_ai_Supabase__apply_migration` con:
- `project_id`: `rtusnruywsmbbzejxooi`
- `name`: `013_clients_companies_shared`
- `query`: el contenido exacto del archivo `.sql` creado en Task 1 (sin los comentarios de cabecera si la tool no los acepta — quitar las primeras 4 líneas de `--` si falla).

Expected: respuesta con `success: true` o equivalente. Si error de sintaxis, leer el mensaje, comparar contra el archivo, corregir y reintentar.

- [ ] **Step 2: Verificar que las policies nuevas existen y las viejas no**

Usar MCP tool `mcp__claude_ai_Supabase__execute_sql` con project_id `rtusnruywsmbbzejxooi`:
```sql
select policyname, cmd
from pg_policies
where schemaname='public' and tablename in ('clients','companies')
order by tablename, cmd;
```

Expected: exactamente estas 8 filas (más las 2 de SELECT que ya existían):
- `clients delete admin / DELETE`
- `clients insert auth / INSERT`
- `clients select all auth / SELECT`
- `clients update auth / UPDATE`
- `companies delete admin / DELETE`
- `companies insert auth / INSERT`
- `companies select all auth / SELECT`
- `companies update auth / UPDATE`

NO debe aparecer `clients write admin` ni `companies write admin`.

- [ ] **Step 3: Smoke test SQL — escritura como autenticado no-admin**

Usar MCP `mcp__claude_ai_Supabase__execute_sql` con project_id `rtusnruywsmbbzejxooi`:
```sql
-- Test desde el rol authenticated (sin admin):
set local role authenticated;
-- Simular un user normal poniendo un JWT claim de un consultor no-admin
-- (esto solo verifica la policy, no garantiza un usuario real — basta).
select has_table_privilege('authenticated','public.clients','INSERT') as can_insert,
       has_table_privilege('authenticated','public.clients','UPDATE') as can_update,
       has_table_privilege('authenticated','public.clients','DELETE') as can_delete;
reset role;
```

Expected: `can_insert=true, can_update=true, can_delete=true` (RLS filtra más abajo — esta query solo confirma que el GRANT de tabla está abierto a authenticated). La barrera real (`is_admin()`) la aplica la policy de DELETE, no este check.

- [ ] **Step 4: Verificar que advisors no se rompió**

Usar MCP `mcp__claude_ai_Supabase__get_advisors` con project_id `rtusnruywsmbbzejxooi`, type `security`.

Expected: no nuevos errores en clients/companies. Es OK si los WARN cosméticos previos (citext, security definer) siguen apareciendo.

---

## Task 3: Modificar helpers JS en `index.html`

**Files:**
- Modify: `C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html` líneas ~1962-1965

- [ ] **Step 1: Aplicar el cambio en `_rawScopedClients`**

Usar el tool Edit con:

`old_string`:
```
const _rawScopedClients=()=>{if(isCEO())return DB.clients;const s=scopedClientIdSet();return DB.clients.filter(c=>s.has(c.id))};
```

`new_string`:
```
/* F-LibretaCompartida: clients = libreta compartida del equipo (todos ven todo). Ownership/comisión sigue en deals.splits[]. */
const _rawScopedClients=()=>DB.clients;
```

- [ ] **Step 2: Aplicar el cambio en `_rawScopedCompanies`**

Usar el tool Edit con:

`old_string`:
```
const _rawScopedCompanies=()=>{if(isCEO())return DB.companies;const s=scopedCompanyIdSet();return DB.companies.filter(co=>s.has(co.id))};
```

`new_string`:
```
/* F-LibretaCompartida: companies = libreta compartida del equipo (todos ven todo). */
const _rawScopedCompanies=()=>DB.companies;
```

- [ ] **Step 3: Verificar que el JS sigue parseando**

Run:
```powershell
$html = Get-Content "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html" -Raw
$lines = $html -split "`n"
$s = 0; for($i=0; $i -lt $lines.Length; $i++){ if($lines[$i].Trim() -eq '<script>'){ $s=$i; break } }
$e = 0; for($i=$lines.Length-1; $i -ge 0; $i--){ if($lines[$i].Trim() -eq '</script>'){ $e=$i; break } }
$lines[($s+1)..($e-1)] -join "`n" | Out-File "$env:TEMP\check.js" -Encoding utf8
node --check "$env:TEMP\check.js"
```
Expected: sin output. Si parser error, abrir el archivo en las líneas afectadas y arreglar.

- [ ] **Step 4: Confirmar que el archivo sigue terminando bien**

Run:
```powershell
Get-Content "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html" -Tail 3
```
Expected: las últimas 3 líneas terminan en `</html>` (o `</body></html>` según formato). Si truncado, restaurar desde git.

- [ ] **Step 5: Confirmar que `scopedClientIdSet` y `scopedCompanyIdSet` siguen vivos (los usa `_rawScopedActivities`)**

Run:
```powershell
Select-String -Path "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM\index.html" -Pattern "scopedClientIdSet|scopedCompanyIdSet" | Measure-Object
```
Expected: Count >= 4 (definición + uso en `_rawScopedActivities` para cada uno). Si Count < 4, algún uso se perdió y hay que investigar.

---

## Task 4: Verificación manual en navegador

**Files:** ninguno. Verificación en runtime.

- [ ] **Step 1: Arrancar servidor local si no está corriendo**

Run (en otra terminal o background):
```powershell
cd "C:\Users\psanz\Desktop\Claudio\CEO Advisors CRM"
python -m http.server 8000
```
Abrir http://localhost:8000 en navegador.

- [ ] **Step 2: Login como un consultor no-admin**

Login con credenciales de un consultor que NO sea CEO ni admin. Si no tienes credenciales a mano, pedir a Pablo o usar las de cualquier consultor real (excepto u1/CEO).

- [ ] **Step 3: Verificar vista Clientes en la consola del navegador**

Abrir devtools → Console. Ejecutar:
```js
console.log('isCEO:', isCEO(), 'isAdmin:', isAdmin(), 'currentUser:', DB.currentUserId);
console.log('DB.clients total:', DB.clients.length);
console.log('scopedClients() total:', scopedClients().length);
console.log('scopedCompanies() total:', scopedCompanies().length);
```

Expected: `scopedClients().length === DB.clients.length` (ajustado por toggle is_demo si está activo). Misma equivalencia para companies.

ANTES del cambio: `scopedClients().length < DB.clients.length` para un no-CEO.
DESPUÉS: son iguales.

- [ ] **Step 4: Navegar a la vista Clientes y contar visualmente**

Click en la sección "Clientes" del sidebar. Contar/scrollear: debe verse la libreta entera (filas demo + reales — depende del toggle). El número en el header debería ser igual al de un login admin/CEO.

Idem para "Empresas".

- [ ] **Step 5: Crear un cliente como consultor no-admin**

Click "Nuevo cliente" → rellenar:
- Nombre: `Test Libreta YYYYMMDD`
- Email: `test-libreta@ejemplo.test`
- Otros campos: vacíos o defaults
Click Guardar.

Esperar 1-2 segundos para que `flushSupabase` se ejecute (debounce 500ms).

- [ ] **Step 6: Verificar en Supabase que el cliente persistió**

Usar MCP `mcp__claude_ai_Supabase__execute_sql` con project_id `rtusnruywsmbbzejxooi`:
```sql
select id, code, name, email, created_at, updated_at, is_demo
from public.clients
where email = 'test-libreta@ejemplo.test'
order by created_at desc
limit 5;
```

Expected: 1 fila con el nombre/email correctos, `is_demo = false`, `created_at` reciente. Si 0 filas: la RLS sigue rechazando (revisar Task 2 Step 2) o `flushSupabase` no llegó a correr (revisar la consola por errores).

- [ ] **Step 7: Verificar que otro consultor (en otra ventana) ve el cliente nuevo**

Abrir ventana incógnito → login como otro consultor no-admin (o como CEO). Ir a la vista Clientes. Debe aparecer `Test Libreta YYYYMMDD`.

(Si Realtime está conectado, debería aparecer en segundos sin refresh manual.)

- [ ] **Step 8: Borrar el cliente de prueba**

Como CEO o admin, en Supabase MCP:
```sql
delete from public.clients where email = 'test-libreta@ejemplo.test';
```

Confirmar que se borró:
```sql
select count(*) from public.clients where email = 'test-libreta@ejemplo.test';
```
Expected: 0.

---

## Task 5: Commit y deploy

**Files:** los cambios de Task 1 y Task 3.

- [ ] **Step 1: Revisar el diff completo**

Run:
```powershell
git status
git diff --stat
git diff index.html
```

Expected:
- `supabase_migrations/013_clients_companies_shared.sql` como Untracked.
- `index.html` modificado (~5 líneas cambiadas, +2 -2).

- [ ] **Step 2: Stage y commit**

Run:
```powershell
git add "supabase_migrations/013_clients_companies_shared.sql" "index.html"
```

```powershell
git commit -m @'
Feat: clients y companies como libreta compartida (F-LibretaCompartida)

- Migration 013: RLS abre INSERT/UPDATE de clients y companies a
  cualquier authenticated. DELETE sigue admin-only.
- index.html: _rawScopedClients y _rawScopedCompanies devuelven la
  coleccion completa (sin filtrar por deals propios).

Implica que un consultor no-admin ve y puede crear/editar la libreta
entera. Ownership/comision se sigue trackeando solo via deals.splits[].
Prerrequisito para el feature de import de clientes desde Excel.

Spec: docs/superpowers/specs/2026-05-19-clientes-empresas-libreta-compartida-design.md
Plan: docs/superpowers/plans/2026-05-19-clientes-empresas-libreta-compartida-implementation.md

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
'@
```

- [ ] **Step 3: Verificar el commit**

Run:
```powershell
git log -1 --stat
```
Expected: 1 nuevo archivo + 1 modificado, mensaje correcto.

- [ ] **Step 4: Push a main (dispara redeploy en Railway)**

Run:
```powershell
git push origin main
```

Expected: push limpio sin rejects ni conflictos.

- [ ] **Step 5: Esperar redeploy de Railway y smoke test en producción**

Esperar ~60-90 segundos. Abrir https://ceo-advisors-crm-production.up.railway.app en navegador, login como consultor no-admin. Repetir verificación de Task 4 Steps 3-4 (consola: `scopedClients().length === DB.clients.length`).

Si todo OK, marcar la implementación como cerrada y avisar a Pablo.

- [ ] **Step 6: Si algo falla en producción — rollback rápido**

Plan de rollback:
1. `git revert HEAD --no-edit && git push origin main` → Railway redeploya la versión anterior.
2. La migración 013 NO se revierte automáticamente. Para revertir las policies, aplicar este SQL vía MCP `execute_sql`:

```sql
drop policy if exists "clients insert auth" on public.clients;
drop policy if exists "clients update auth" on public.clients;
drop policy if exists "clients delete admin" on public.clients;
create policy "clients write admin" on public.clients
  for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists "companies insert auth" on public.companies;
drop policy if exists "companies update auth" on public.companies;
drop policy if exists "companies delete admin" on public.companies;
create policy "companies write admin" on public.companies
  for all using (public.is_admin()) with check (public.is_admin());
```

Filas insertadas por consultores no-admin durante la ventana del experimento quedarán en Supabase (no se borran) — admin puede limpiarlas con un DELETE selectivo si hace falta.

---

## Definition of Done

- [ ] Migration `013_clients_companies_shared.sql` existe en repo y está aplicada en Supabase remoto.
- [ ] `pg_policies` muestra las 4 policies nuevas por tabla, las viejas `write admin` no están.
- [ ] `index.html` modificado, `node --check` pasa, archivo termina en `</html>`.
- [ ] Como consultor no-admin: `scopedClients().length === DB.clients.length` (post is_demo filter).
- [ ] Como consultor no-admin: crear cliente → persiste en Supabase → visible para otro consultor en tiempo real.
- [ ] Commit pusheado a main, deploy Railway OK, smoke test en producción pasa.
- [ ] Pablo notificado.
