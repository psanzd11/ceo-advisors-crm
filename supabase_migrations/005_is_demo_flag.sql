-- ═══════════════════════════════════════════════════════════════════
-- CEO Advisors CRM — Migration 005: Flag is_demo
-- Generated: 2026-05-11 (Fase 15.1 extra)
--
-- Los datos transaccionales (clients/companies/deals/activities) del
-- CRM actual son demo/prueba. Esta migration añade una columna
-- `is_demo boolean default false` a las 4 tablas + índices parciales
-- para optimizar la query "WHERE is_demo = false" que será la común
-- en producción.
--
-- Pupilos NO se marca (datos reales del programa, según decisión del
-- usuario el 2026-05-11).
--
-- Estrategia de reemplazo:
-- 1. F15.2 importer pondrá is_demo=true en todas las filas del Excel actual.
-- 2. Cuando Pablo cree clientes reales desde la web, is_demo=false (default).
-- 3. Cuando llegue el dataset real completo, ejecutar:
--      DELETE FROM activities WHERE is_demo = true;
--      DELETE FROM deals      WHERE is_demo = true;
--      DELETE FROM clients    WHERE is_demo = true;
--      DELETE FROM companies  WHERE is_demo = true;
--    (en este orden para respetar FKs).
-- ═══════════════════════════════════════════════════════════════════

alter table public.clients    add column is_demo boolean not null default false;
alter table public.companies  add column is_demo boolean not null default false;
alter table public.deals      add column is_demo boolean not null default false;
alter table public.activities add column is_demo boolean not null default false;

-- Índices parciales: optimizan la query "datos reales" sin coste cuando demos < 50%.
-- Postgres puede recorrer estos indexes sin tocar las filas is_demo=true.
create index idx_clients_not_demo    on public.clients(id)    where is_demo = false;
create index idx_companies_not_demo  on public.companies(id)  where is_demo = false;
create index idx_deals_not_demo      on public.deals(id)      where is_demo = false;
create index idx_activities_not_demo on public.activities(id) where is_demo = false;

comment on column public.clients.is_demo    is 'true = fila de prueba/demo. Filtrar con WHERE is_demo=false en producción.';
comment on column public.companies.is_demo  is 'true = fila de prueba/demo';
comment on column public.deals.is_demo      is 'true = fila de prueba/demo';
comment on column public.activities.is_demo is 'true = fila de prueba/demo';
