-- F-Chatbot: tabla + RPC atómico para rate limiting del chatbot IA.
-- Cada usuario tiene un cap de 30 mensajes por hora.
-- La edge function chat-assistant llama al RPC en cada turno.
--
-- Aplicada: 2026-05-15 vía MCP (mcp__claude_ai_Supabase__apply_migration)

create table if not exists public.chat_rate_limits (
  user_id     uuid not null,
  hour_bucket integer not null,
  count       integer not null default 0,
  primary key (user_id, hour_bucket)
);

create index if not exists chat_rate_limits_bucket_idx
  on public.chat_rate_limits (hour_bucket);

-- RLS: solo accesible desde service role. El cliente nunca consulta esta tabla
-- directamente; solo la edge function vía RPC.
alter table public.chat_rate_limits enable row level security;

-- RPC atómico: incrementa el contador del bucket y devuelve si está dentro del límite.
-- security definer para que el authenticated role pueda invocarlo sin acceso directo
-- a la tabla.
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

-- Limpieza opcional: los buckets viejos (>48h) no tienen valor.
-- Si en el futuro la tabla crece, considerar pg_cron diario:
--   delete from public.chat_rate_limits where hour_bucket < (extract(epoch from now())/3600 - 48)::int;
