-- ═══════════════════════════════════════════════════════════════════
-- CEO Advisors CRM — Migration 004: Harden trigger function
-- Generated: 2026-05-10 (Fase 15.1)
--
-- handle_new_auth_user es trigger-only. No tiene sentido que sea
-- callable como RPC desde el cliente. Revocamos EXECUTE de todos
-- los roles públicos. El trigger sigue funcionando porque se ejecuta
-- bajo el rol postgres internamente.
-- ═══════════════════════════════════════════════════════════════════

revoke execute on function public.handle_new_auth_user() from anon, authenticated, public;
