-- F15.5: server-side sequential code generation
-- Elimina race condition cuando 2 advisors offline crean entidades del mismo prefijo:
-- antes ambos computaban d1 localmente; al sincronizar, uno entraba al server y
-- el otro quedaba en quarantine silenciosa. Ahora el cliente pide código al server.
--
-- Aplicada: 2026-05-18 vía MCP apply_migration

create table if not exists public.code_sequences (
  prefix text primary key,
  last_n integer not null default 0,
  updated_at timestamptz not null default now()
);

-- Seed con el MAX(N) actual de cada tabla, para no chocar con códigos preexistentes.
insert into public.code_sequences (prefix, last_n) values
  ('u',  coalesce((select max((substring(code from '\d+$'))::int) from public.consultants where code ~ '^u\d+$'),  0)),
  ('c',  coalesce((select max((substring(code from '\d+$'))::int) from public.clients     where code ~ '^c\d+$'),  0)),
  ('co', coalesce((select max((substring(code from '\d+$'))::int) from public.companies   where code ~ '^co\d+$'), 0)),
  ('d',  coalesce((select max((substring(code from '\d+$'))::int) from public.deals       where code ~ '^d\d+$'),  0)),
  ('a',  coalesce((select max((substring(code from '\d+$'))::int) from public.activities  where code ~ '^a\d+$'),  0)),
  ('p',  coalesce((select max((substring(code from '\d+$'))::int) from public.pupilos     where code ~ '^p\d+$'),  0))
on conflict (prefix) do nothing;

alter table public.code_sequences enable row level security;
-- Sin policies = sin acceso directo. Solo el RPC (security definer) la toca.

-- RPC atómico: reserva N códigos consecutivos para un prefix y devuelve sus enteros.
-- Garantía: UPDATE ... RETURNING en postgres es atómico, dos llamadas concurrentes
-- nunca devuelven solapamiento.
create or replace function public.next_code(p_prefix text, p_count int default 1)
returns int[]
language plpgsql
security definer
set search_path = public
as $$
declare
  v_new_last int;
begin
  if p_count < 1 or p_count > 1000 then
    raise exception 'next_code: p_count must be between 1 and 1000 (got %)', p_count;
  end if;
  if p_prefix is null or p_prefix !~ '^[a-z]{1,4}$' then
    raise exception 'next_code: invalid prefix %', p_prefix;
  end if;

  insert into public.code_sequences (prefix, last_n)
  values (p_prefix, 0)
  on conflict (prefix) do nothing;

  update public.code_sequences
    set last_n = last_n + p_count,
        updated_at = now()
    where prefix = p_prefix
  returning last_n into v_new_last;

  return array(select generate_series(v_new_last - p_count + 1, v_new_last));
end;
$$;

grant execute on function public.next_code(text, int) to authenticated;
