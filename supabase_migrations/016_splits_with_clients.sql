-- F16.4: Splits con clientes — atribución real de revenue
--
-- Modelo anterior: splits = [{u: uuid, pct: int}]
-- Modelo nuevo:    splits = [{kind: 'u'|'c', id: uuid, pct: int}]
--
-- Aplicada: 2026-05-27 vía MCP apply_migration

-- Paso 1: transformar todas las filas existentes al nuevo formato.
update public.deals d
set splits = coalesce(
  (select jsonb_agg(
    case
      when s ? 'kind' then s
      else jsonb_build_object('kind','u','id', s->>'u','pct', (s->>'pct')::int)
    end
  )
   from jsonb_array_elements(d.splits) s),
  '[]'::jsonb
)
where d.splits is not null and jsonb_typeof(d.splits) = 'array';

-- Paso 2: reescribir policies RLS para el nuevo formato.
-- Un consultor sigue viendo/editando los deals donde aparece como kind='u' en splits.
-- Clientes en splits no autentican (no tienen RLS personal): siguen siendo "datos del deal".
drop policy if exists "deals update own/admin" on public.deals;
create policy "deals update own/admin" on public.deals
  for update
  using (
    is_admin() OR (
      my_consultant_id() IS NOT NULL
      AND splits @> jsonb_build_array(jsonb_build_object('kind','u','id',(my_consultant_id())::text))
    )
  )
  with check (auth.uid() is not null);

drop policy if exists "deals delete own/admin" on public.deals;
create policy "deals delete own/admin" on public.deals
  for delete
  using (
    is_admin() OR (
      my_consultant_id() IS NOT NULL
      AND splits @> jsonb_build_array(jsonb_build_object('kind','u','id',(my_consultant_id())::text))
    )
  );
