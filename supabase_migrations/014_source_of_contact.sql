-- F16.2: source of contact en empresas
-- Tres campos nuevos en companies:
--   source_type: 'consultant' | 'client' | 'other' | NULL
--   source_ref:  UUID de consultant o client (NULL para 'other' o sin source). Sin FK porque
--                la referencia es polimórfica (apunta a dos tablas distintas según source_type).
--   source_note: texto libre, útil sobre todo para source_type='other'.
--
-- Aplicada: 2026-05-27 vía MCP apply_migration

alter table public.companies
  add column if not exists source_type text,
  add column if not exists source_ref  uuid,
  add column if not exists source_note text;

alter table public.companies
  drop constraint if exists companies_source_type_chk;
alter table public.companies
  add constraint companies_source_type_chk
  check (source_type is null or source_type in ('consultant','client','other'));

-- Coherencia: si source_type es consultant/client, source_ref debería estar presente; si es 'other'
-- source_ref es NULL y se usa source_note. No es restricción dura — permitimos source_type sin ref
-- temporalmente porque la UI puede crear empresa antes de elegir referencia.

-- Actualizamos el RPC upsert_companies_if_newer para serializar los tres campos nuevos.
create or replace function public.upsert_companies_if_newer(rows jsonb)
returns setof uuid
language plpgsql
set search_path = public
as $$
declare r jsonb; applied_id uuid;
begin
  for r in select * from jsonb_array_elements(rows) loop
    insert into public.companies (
      id, code, is_demo, name, industry, country, employees, net_worth, website, client_ids, notes, comments,
      source_type, source_ref, source_note,
      updated_at
    ) values (
      coalesce(nullif(r->>'id','')::uuid, gen_random_uuid()),
      r->>'code', coalesce((r->>'is_demo')::boolean,false),
      r->>'name', r->>'industry', r->>'country', coalesce((r->>'employees')::int,0),
      coalesce((r->>'net_worth')::bigint,0), r->>'website',
      coalesce(r->'client_ids','[]'::jsonb), r->>'notes',
      coalesce(r->'comments','[]'::jsonb),
      nullif(r->>'source_type',''),
      nullif(r->>'source_ref','')::uuid,
      r->>'source_note',
      coalesce((r->>'updated_at')::timestamptz, now())
    )
    on conflict (code) do update set
      is_demo=excluded.is_demo, name=excluded.name,
      industry=excluded.industry, country=excluded.country, employees=excluded.employees,
      net_worth=excluded.net_worth, website=excluded.website,
      client_ids=excluded.client_ids, notes=excluded.notes, comments=excluded.comments,
      source_type=excluded.source_type, source_ref=excluded.source_ref, source_note=excluded.source_note,
      updated_at=excluded.updated_at
    where excluded.updated_at >= public.companies.updated_at
    returning id into applied_id;
    if applied_id is not null then return next applied_id; end if;
    applied_id := null;
  end loop;
end; $$;
