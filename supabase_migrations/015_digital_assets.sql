-- F16.3: Digital Assets — materiales, presentaciones, lecturas y guías compartidas por el equipo.
--
-- Aplicada: 2026-05-27 vía MCP apply_migration

create table if not exists public.digital_assets (
  id              uuid primary key default gen_random_uuid(),
  code            text unique not null,
  name            text not null,
  type            text not null check (type in ('material','presentacion','lectura','guia')),
  file_path       text,
  file_size_bytes bigint,
  mime_type       text,
  description     text,
  tags            text[] default '{}',
  created_by      uuid references public.consultants(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  is_demo         boolean not null default false
);

create index if not exists digital_assets_type_idx     on public.digital_assets(type);
create index if not exists digital_assets_created_idx  on public.digital_assets(created_at desc);

alter table public.digital_assets enable row level security;

-- SELECT: cualquier autenticado (los assets son una biblioteca compartida).
drop policy if exists digital_assets_select on public.digital_assets;
create policy digital_assets_select on public.digital_assets
  for select to authenticated using (true);

-- INSERT: el propio uploader o admin.
drop policy if exists digital_assets_insert on public.digital_assets;
create policy digital_assets_insert on public.digital_assets
  for insert to authenticated
  with check (public.is_admin() or created_by = public.my_consultant_id());

-- UPDATE: el uploader o admin.
drop policy if exists digital_assets_update on public.digital_assets;
create policy digital_assets_update on public.digital_assets
  for update to authenticated
  using (public.is_admin() or created_by = public.my_consultant_id())
  with check (public.is_admin() or created_by = public.my_consultant_id());

-- DELETE: solo admin.
drop policy if exists digital_assets_delete on public.digital_assets;
create policy digital_assets_delete on public.digital_assets
  for delete to authenticated using (public.is_admin());

-- Code generator: añade el prefijo "da" a la secuencia central (next_code RPC) para que
-- los códigos sean monotónicos cross-cliente.
insert into public.code_sequences (prefix, last_n)
values ('da', coalesce((select max((substring(code from '\d+$'))::int) from public.digital_assets where code ~ '^da\d+$'), 0))
on conflict (prefix) do nothing;

-- RPC upsert_digital_assets_if_newer: idéntico patrón al resto de tablas, last-write-wins por updated_at.
create or replace function public.upsert_digital_assets_if_newer(rows jsonb)
returns setof uuid
language plpgsql
set search_path = public
as $$
declare r jsonb; applied_id uuid;
begin
  for r in select * from jsonb_array_elements(rows) loop
    insert into public.digital_assets (
      id, code, is_demo, name, type, file_path, file_size_bytes, mime_type, description, tags, created_by, updated_at
    ) values (
      coalesce(nullif(r->>'id','')::uuid, gen_random_uuid()),
      r->>'code', coalesce((r->>'is_demo')::boolean,false),
      r->>'name', r->>'type', r->>'file_path',
      nullif(r->>'file_size_bytes','')::bigint,
      r->>'mime_type', r->>'description',
      coalesce(array(select jsonb_array_elements_text(r->'tags')), '{}'),
      nullif(r->>'created_by','')::uuid,
      coalesce((r->>'updated_at')::timestamptz, now())
    )
    on conflict (code) do update set
      is_demo=excluded.is_demo, name=excluded.name, type=excluded.type,
      file_path=excluded.file_path, file_size_bytes=excluded.file_size_bytes,
      mime_type=excluded.mime_type, description=excluded.description, tags=excluded.tags,
      updated_at=excluded.updated_at
    where excluded.updated_at >= public.digital_assets.updated_at
    returning id into applied_id;
    if applied_id is not null then return next applied_id; end if;
    applied_id := null;
  end loop;
end; $$;

grant execute on function public.upsert_digital_assets_if_newer(jsonb) to authenticated;

-- Bucket Storage privado. Acceso via signed URLs (1h) generadas on demand desde el cliente.
insert into storage.buckets (id, name, public)
values ('digital-assets', 'digital-assets', false)
on conflict (id) do nothing;

drop policy if exists "digital-assets read"   on storage.objects;
create policy "digital-assets read" on storage.objects
  for select to authenticated using (bucket_id = 'digital-assets');

drop policy if exists "digital-assets insert" on storage.objects;
create policy "digital-assets insert" on storage.objects
  for insert to authenticated with check (bucket_id = 'digital-assets');

drop policy if exists "digital-assets update" on storage.objects;
create policy "digital-assets update" on storage.objects
  for update to authenticated using (bucket_id = 'digital-assets' and (owner = auth.uid() or public.is_admin()));

drop policy if exists "digital-assets delete" on storage.objects;
create policy "digital-assets delete" on storage.objects
  for delete to authenticated using (bucket_id = 'digital-assets' and (owner = auth.uid() or public.is_admin()));
