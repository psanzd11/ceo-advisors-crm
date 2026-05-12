-- F15.4b: campos colaborativos perdidos en F15.0
alter table public.deals
  add column if not exists comments      jsonb default '[]'::jsonb,
  add column if not exists stage_history jsonb default '[]'::jsonb,
  add column if not exists lost_reason   text,
  add column if not exists won_at        date,
  add column if not exists lost_at       date,
  add column if not exists tags          jsonb default '[]'::jsonb;
alter table public.clients
  add column if not exists comments jsonb default '[]'::jsonb,
  add column if not exists tags     jsonb default '[]'::jsonb;
alter table public.companies
  add column if not exists comments jsonb default '[]'::jsonb;
alter table public.activities
  add column if not exists assigned_to uuid references public.consultants(id) on delete set null;
alter table public.consultants
  add column if not exists prefs jsonb default '{}'::jsonb;

create or replace function public.purge_client_from_companies()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.companies
    set client_ids = coalesce((
      select jsonb_agg(elem)
      from jsonb_array_elements(client_ids) elem
      where elem::text <> to_jsonb(OLD.id::text)::text
    ), '[]'::jsonb)
    where client_ids @> to_jsonb(array[OLD.id::text]);
  return OLD;
end;
$$;
revoke execute on function public.purge_client_from_companies() from anon, authenticated, public;
drop trigger if exists clients_purge_companies on public.clients;
create trigger clients_purge_companies before delete on public.clients
  for each row execute function public.purge_client_from_companies();
create index if not exists idx_activities_assigned_to on public.activities(assigned_to);
