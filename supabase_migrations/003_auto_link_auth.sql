-- ═══════════════════════════════════════════════════════════════════
-- CEO Advisors CRM — Migration 003: Auto-link auth.users a consultants
-- Generated: 2026-05-10 (Fase 15.1)
--
-- Cuando un consultant acepta la invitación de Supabase Auth y crea
-- su cuenta, su auth.users.id se vincula automáticamente a la fila
-- consultants existente que tenga el mismo email.
--
-- Sin este trigger, F15.3 requeriría un paso manual: cada consultor
-- tendría que "reclamar" su perfil. Con esto, el flujo es:
--   1. F15.2 importa Excel → consultants creados con auth_user_id=null
--   2. F15.2 envía invitación por email
--   3. Consultor pone password → se crea auth.users row
--   4. Este trigger detecta el match por email y vincula auth_user_id
--   5. Próxima vez que abra el CRM, is_admin()/my_consultant_id() ya funcionan
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  -- Match case-insensitive por email. Sólo vincula si la columna está libre
  -- (evita pisar un link existente si alguien re-registra).
  update public.consultants
     set auth_user_id = new.id
   where lower(email) = lower(new.email)
     and auth_user_id is null;
  return new;
end;
$$;

comment on function public.handle_new_auth_user() is
  'Trigger function: cuando se crea un auth.users, busca match por email en consultants y rellena auth_user_id. Idempotente — sólo escribe si está null.';

-- Trigger en auth.users (no en public).
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();
