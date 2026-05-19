# Clientes y empresas como libreta compartida

**Fecha:** 2026-05-19
**Estado:** Aprobado por Pablo
**Autor:** brainstorming session
**Spec previo relacionado:** ninguno
**Spec siguiente:** Import de clientes desde Excel (dependerá de este)

---

## 1. Motivación

Hoy un cliente o empresa solo aparece en la vista de un consultor si está vinculado a un deal donde él aparece en `splits[]`. Si el deal nunca se abre, o se pierde, el contacto desaparece de su vista.

Esto rompe el flujo CRM clásico — "primero capturo el contacto, luego abro deal cuando madura" — y bloquea funcionalidad pendiente (importar libretas de contactos desde Excel, prospección, follow-up sin pipeline activo).

**Decisión de Pablo:** los clientes y empresas son una libreta compartida del equipo. Todos los consultores ven todo. La ownership / commission tracking vive solo en `deals.splits[]`, que es donde tiene sentido funcional. El concepto "mis clientes" deja de existir en la vista de consultores.

## 2. Alcance

### Dentro
- Cambiar los helpers `_rawScopedClients` y `_rawScopedCompanies` en `index.html` para devolver toda la libreta, no solo los vinculados a deals propios.
- Añadir policies RLS en Postgres para que cualquier `authenticated` pueda INSERT/UPDATE en `clients` y `companies`.
- Mantener DELETE restringido a admin/CEO.
- Migración `013_clients_companies_shared.sql`.

### Fuera (futuros specs)
- Import de clientes/empresas/deals desde Excel para consultores.
- Filtro opcional "Mis clientes" en la vista compartida (solo si Pablo lo pide tras observar el uso real).
- Transferencia/ownership explícita de contactos.
- Compartir activities (siguen siendo "mías" via deals y assigned_to).

## 3. Cambios en cliente (`index.html`)

Los helpers de scoping para clients y companies se simplifican a devolver la colección entera:

```js
const _rawScopedClients   = () => DB.clients;
const _rawScopedCompanies = () => DB.companies;
// scopedClients() / scopedCompanies() siguen aplicando el filtro is_demo encima (sin cambios).
```

`scopedClientIdSet()` y `scopedCompanyIdSet()` se conservan **solo** porque `_rawScopedActivities()` los usa para filtrar actividades vinculadas a deals/clientes con deals propios. Activities NO entra en este spec; siguen funcionando como hoy (cada consultor ve solo las suyas).

### Impactos UX observables

| Vista | Hoy (consultor no-CEO) | Tras cambio |
|---|---|---|
| Lista de Clientes | Solo los con deal mío | Toda la libreta (136+ filas hoy) |
| Lista de Empresas | Solo las con deal mío | Toda la libreta |
| Dashboard `Today` (Net Worth total, # clientes, mapa países) | Reflejaba "lo mío" | Reflejará la libreta entera |
| Botón "Nuevo cliente" / "Nueva empresa" | Disponible (sin cambio) | Disponible — pero ahora la fila creada aparece para todos |
| Toggle "Ocultar demo" | Funciona | Funciona igual |
| Vista Deals | Sin cambio (siempre fue "mis deals") | Sin cambio |
| Vista Activities | Sin cambio (mis actividades) | Sin cambio |

**Riesgo conocido:** las métricas del dashboard personal del consultor cambiarán de magnitud (pasan de mostrar su porción a la libreta entera). Es coherente con el modelo "libreta compartida" pero es un cambio visible. Si tras desplegar Pablo o el equipo lo encuentran ruidoso, abrimos un spec para añadir un toggle "Mis (vía deals) / Todos" en el header de Clientes y Empresas — sin volver atrás en el modelo de datos.

### Permisos en UI
- Botón "Nuevo cliente / empresa": el UI lo muestra hoy, pero las RLS actuales (`write admin`) hacen que el insert falle vía Supabase para consultores no-admin. Tras este cambio, el insert funcionará para cualquier autenticado. No hay que tocar UI aquí — solo la migración cambia el comportamiento.
- Edición de cliente/empresa (drawer): mismo patrón. UI ya lo permite; el update fallaba en RLS para no-admins; tras este cambio funcionará.
- Borrado: en la UI sigue mostrándose el botón, pero las RLS seguirán rechazando el DELETE para no-admins. Añadir guard en cliente que oculte/deshabilite el botón borrar si `!isCEO() && !isAdmin()`, para evitar UX confusa donde el usuario hace click y le sale error de Supabase sin contexto.

## 4. Migración Postgres (`013_clients_companies_shared.sql`)

```sql
-- Clients: INSERT/UPDATE para cualquier auth, DELETE solo admin
drop policy if exists "clients write admin" on public.clients;

create policy "clients insert auth" on public.clients
  for insert to authenticated with check (auth.uid() is not null);

create policy "clients update auth" on public.clients
  for update to authenticated
  using (auth.uid() is not null)
  with check (auth.uid() is not null);

create policy "clients delete admin" on public.clients
  for delete to authenticated using (public.is_admin());

-- Companies: idéntico patrón
drop policy if exists "companies write admin" on public.companies;

create policy "companies insert auth" on public.companies
  for insert to authenticated with check (auth.uid() is not null);

create policy "companies update auth" on public.companies
  for update to authenticated
  using (auth.uid() is not null)
  with check (auth.uid() is not null);

create policy "companies delete admin" on public.companies
  for delete to authenticated using (public.is_admin());
```

**No se toca:**
- SELECT policy (`select all auth`) — sigue permitiendo a todos los autenticados leer todo.
- Triggers (`clients_set_updated`, `clients_purge_companies`, `companies_set_updated`).
- RLS de `deals`, `activities`, `consultants`, `pupilos`, `notifications`, `activity_log`.
- RPCs `upsert_clients_if_newer` y `upsert_companies_if_newer` siguen funcionando — las policies les aplican igual.

**Verificación post-migración:**
1. Login como consultor no-admin → `insert into clients (code, name) values ('cTest', 'Test')` debe funcionar.
2. Mismo consultor → `delete from clients where code = 'cTest'` debe fallar con RLS error.
3. Login como admin → ambos funcionan.

## 5. Riesgos y mitigaciones

| Riesgo | Severidad | Mitigación |
|---|---|---|
| Dos consultores editan el mismo cliente a la vez | Bajo | Ya cubierto por `upsert_clients_if_newer` (last-write-wins) + Realtime echo filter. |
| Consultor X modifica un cliente que "usa" Y sin avisar | Medio | Aceptado por diseño (libreta compartida). El audit log (`activity_log`) permite trazabilidad post-hoc. Si abusan, hablamos. |
| Métricas del dashboard cambian de magnitud (cambio visible) | Medio | Documentado. Si molesta, spec posterior añade toggle "Mis/Todos". |
| Demo data mezclada con reales | Bajo | Toggle "Ocultar demo" sigue funcionando como hoy. |
| Borrado masivo accidental | Bajo | DELETE sigue requiriendo admin. |
| Consultor intenta borrar y le sale RLS error sin contexto | Bajo | Mitigado: ocultar/deshabilitar botón borrar en UI para no-admins. |
| Snapshot key `_supa_snapshot_v2` queda obsoleto si cambia algo del payload | Bajo | No cambia el `_supaToRow` para clients/companies; el snapshot key se mantiene v2. |

## 6. Plan de implementación (alto nivel)

Sin entrar en detalle (eso es el plan):

1. Crear y aplicar migration `013_clients_companies_shared.sql` vía MCP `apply_migration`.
2. Modificar `_rawScopedClients` y `_rawScopedCompanies` en `index.html`.
3. Añadir guard en UI: ocultar botón "Borrar" en cliente/empresa para no-admins.
4. Verificación manual: como consultor no-admin, crear cliente, editar, intentar borrar (debe fallar limpiamente).
5. Verificación: dashboard refleja libreta entera.
6. Deploy a Railway, smoke test en producción.

## 7. Decisiones tomadas

- **Sin `owner_consultant_id`** en clients/companies. La ownership ya está modelada implícitamente vía `deals.splits[]`. Añadir un owner explícito duplicaría el modelo y crearía conflicto entre "yo soy owner" vs "yo estoy en split".
- **Sin backfill heurístico** — no hay nada que rellenar, no hay columna nueva.
- **Sin filtro "Mis/Todos" inicialmente** — Pablo decidió eliminar el concepto "mis clientes" de la vista de consultores. Si en uso real se nota ruido, lo añadimos como toggle no destructivo.
- **DELETE admin-only** — protección anti-error humano sobre la libreta compartida.
- **Activities no cambian** — siguen siendo privadas a cada consultor (sus deals/asignaciones). Pablo no lo solicitó y mezcla activities compartidas con privacidad de notas internas sería otro debate.
