-- F15.5: hardening del RPC consultants para que una fila con email/auth_user_id duplicado
-- no tire toda la batch. Cada fila se ejecuta en su propio sub-bloque con EXCEPTION handler.
-- Las demás (clients/companies/deals/activities/pupilos) NO necesitan este patch porque
-- solo tienen unique(code), que ya está cubierto por ON CONFLICT.
--
-- Aplicada: 2026-05-15 vía MCP (mcp__claude_ai_Supabase__apply_migration)

CREATE OR REPLACE FUNCTION public.upsert_consultants_if_newer(rows jsonb)
RETURNS SETOF uuid
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
declare
  r jsonb;
  applied_id uuid;
begin
  for r in select * from jsonb_array_elements(rows) loop
    begin
      insert into public.consultants (
        id, code, name, role, is_ceo, is_admin, email, region, bio, prefs, updated_at
      ) values (
        coalesce(nullif(r->>'id','')::uuid, gen_random_uuid()),
        r->>'code', r->>'name', r->>'role',
        coalesce((r->>'is_ceo')::boolean,false), coalesce((r->>'is_admin')::boolean,false),
        nullif(r->>'email','')::citext, r->>'region', r->>'bio',
        coalesce(r->'prefs','{}'::jsonb),
        coalesce((r->>'updated_at')::timestamptz, now())
      )
      on conflict (code) do update set
        name=excluded.name, role=excluded.role,
        is_ceo=excluded.is_ceo, is_admin=excluded.is_admin, email=excluded.email,
        region=excluded.region, bio=excluded.bio, prefs=excluded.prefs,
        updated_at=excluded.updated_at
      where excluded.updated_at >= public.consultants.updated_at
      returning id into applied_id;

      if applied_id is not null then
        return next applied_id;
      end if;
      applied_id := null;

    exception
      when unique_violation then
        raise notice '[upsert_consultants_if_newer] skip code=% por unique_violation: %',
          r->>'code', SQLERRM;
        applied_id := null;
        continue;
    end;
  end loop;
end;
$function$;
