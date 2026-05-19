-- F-LibretaCompartida (2026-05-19)
-- Applied via MCP 2026-05-19 · version 20260519192458
-- Convierte clients y companies en libreta compartida: cualquier autenticado
-- puede INSERT/UPDATE. DELETE sigue restringido a admin/CEO.
-- Mantiene SELECT abierto a authenticated (sin cambio respecto a 001).
--
-- IDEMPOTENTE: las policies pueden existir ya — la migration `rls_collaborative`
-- (aplicada vía MCP el 2026-05-12, sin archivo .sql en repo; version 20260512131154)
-- puede haberlas dejado en este estado. Los drops cubren todas las variantes
-- conocidas para que el apply sea no-op si ya están aplicadas.
-- El predicado `auth.uid() is not null` es redundante con `to authenticated` pero
-- mantiene consistencia de estilo con las policies `select all auth` definidas
-- en `001_initial_schema.sql`.

-- ─── clients ────────────────────────────────────────────────────
drop policy if exists "clients write admin"  on public.clients;
drop policy if exists "clients insert auth"  on public.clients;
drop policy if exists "clients update auth"  on public.clients;
drop policy if exists "clients delete admin" on public.clients;

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
drop policy if exists "companies write admin"  on public.companies;
drop policy if exists "companies insert auth"  on public.companies;
drop policy if exists "companies update auth"  on public.companies;
drop policy if exists "companies delete admin" on public.companies;

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

