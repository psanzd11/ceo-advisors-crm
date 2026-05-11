-- ═══════════════════════════════════════════════════════════════════
-- CEO Advisors CRM — Migration 001: Initial Schema
-- Project: rtusnruywsmbbzejxooi (CRM - CEO Advisors)
-- Generated: 2026-05-10 (Fase 15.0)
-- Schema version target: 2026.05.1 (paridad con inject_data.py)
-- ═══════════════════════════════════════════════════════════════════

-- ── EXTENSIONS ──────────────────────────────────────────
create extension if not exists "uuid-ossp" schema extensions;
create extension if not exists pgcrypto schema extensions;
create extension if not exists citext;
create extension if not exists moddatetime schema extensions;

-- ── ENUM TYPES ──────────────────────────────────────────
create type public.deal_type   as enum ('mandate','retainer','equity','board','advisor','other');
create type public.deal_stage  as enum ('lead','contact','proposal','negotiation','won','lost','on-hold');
create type public.client_tier as enum ('A','B','C','D');
create type public.activity_type as enum ('meeting','call','email','note','task','other');

-- ═══════════════════════════════════════════════════════════════════
-- CORE TABLES
-- ═══════════════════════════════════════════════════════════════════

-- 1. CONSULTANTS ─────────────────────────────────────────
create table public.consultants (
  id            uuid primary key default uuid_generate_v4(),
  code          text unique not null,           -- 'u1', 'u2' (paridad HTML actual)
  auth_user_id  uuid unique references auth.users(id) on delete set null,
  name          text not null,
  role          text default 'Advisor',
  is_ceo        boolean default false,
  is_admin      boolean default false,
  email         citext unique,
  region        text,
  bio           text,
  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);
comment on column public.consultants.code is 'Código corto legible (u1, u2) — paridad con HTML actual';
comment on column public.consultants.auth_user_id is 'Link a auth.users; null durante migración inicial, populado al primer login';

-- 2. CLIENTS ─────────────────────────────────────────────
create table public.clients (
  id          uuid primary key default uuid_generate_v4(),
  code        text unique not null,             -- 'c1'
  name        text not null,
  email       citext,
  phone       text,
  country     text,
  city        text,
  net_worth   bigint default 0,                 -- USD
  source      text,
  tier        client_tier,
  notes       text,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);

-- 3. COMPANIES ───────────────────────────────────────────
create table public.companies (
  id          uuid primary key default uuid_generate_v4(),
  code        text unique not null,             -- 'co1'
  name        text not null,
  industry    text,
  country     text,
  employees   integer default 0,
  net_worth   bigint default 0,
  website     text,
  client_ids  jsonb default '[]'::jsonb,        -- array de UUIDs de clients
  notes       text,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);

-- 4. DEALS ───────────────────────────────────────────────
create table public.deals (
  id          uuid primary key default uuid_generate_v4(),
  code        text unique not null,             -- 'd1'
  title       text not null,
  client_id   uuid references public.clients(id) on delete set null,
  company_id  uuid references public.companies(id) on delete set null,
  type        deal_type default 'mandate',
  stage       deal_stage default 'lead',
  amount      bigint default 0,                 -- USD
  close_date  date,
  splits      jsonb default '[]'::jsonb,        -- [{"u":"<consultant_uuid>","pct":50}]
  notes       text,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);

-- 5. ACTIVITIES ──────────────────────────────────────────
create table public.activities (
  id          uuid primary key default uuid_generate_v4(),
  code        text unique not null,             -- 'a1'
  type        activity_type default 'note',
  date        date,
  client_id   uuid references public.clients(id) on delete set null,
  company_id  uuid references public.companies(id) on delete set null,
  deal_id     uuid references public.deals(id)   on delete set null,
  title       text,
  notes       text,
  done        boolean default false,
  created_by  uuid references public.consultants(id) on delete set null,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);

-- 6. PUPILOS ─────────────────────────────────────────────
create table public.pupilos (
  id              uuid primary key default uuid_generate_v4(),
  code            text unique not null,         -- 'p1'
  name            text not null,
  email           citext,
  university      text,
  program         text,
  start_date      date,
  end_date        date,
  mentor          text,
  region          text,
  consultant_id   uuid references public.consultants(id) on delete set null,
  left_company    text,
  left_role       text,
  notes           text,
  docs            jsonb default '[]'::jsonb,    -- array de paths a CVs/docs
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

-- 7. ACTIVITY_LOG (audit trail) ──────────────────────────
create table public.activity_log (
  id          uuid primary key default uuid_generate_v4(),
  ts          timestamptz default now(),
  user_id     uuid references auth.users(id) on delete set null,
  action      text not null,                    -- 'create', 'update', 'delete', 'login', etc.
  entity      text,                             -- 'client', 'deal', etc.
  entity_id   uuid,
  metadata    jsonb
);

-- ═══════════════════════════════════════════════════════════════════
-- INDEXES
-- ═══════════════════════════════════════════════════════════════════
create index idx_deals_client_id   on public.deals(client_id);
create index idx_deals_company_id  on public.deals(company_id);
create index idx_deals_stage       on public.deals(stage);
create index idx_deals_close_date  on public.deals(close_date);
create index idx_deals_splits_gin  on public.deals using gin (splits jsonb_path_ops);

create index idx_activities_client    on public.activities(client_id);
create index idx_activities_deal      on public.activities(deal_id);
create index idx_activities_company   on public.activities(company_id);
create index idx_activities_created_by on public.activities(created_by);
create index idx_activities_date      on public.activities(date);

create index idx_pupilos_consultant on public.pupilos(consultant_id);
create index idx_activity_log_ts    on public.activity_log(ts desc);
create index idx_activity_log_user  on public.activity_log(user_id, ts desc);

-- ═══════════════════════════════════════════════════════════════════
-- UPDATED_AT TRIGGERS (moddatetime)
-- ═══════════════════════════════════════════════════════════════════
create trigger consultants_set_updated  before update on public.consultants  for each row execute function extensions.moddatetime(updated_at);
create trigger clients_set_updated      before update on public.clients      for each row execute function extensions.moddatetime(updated_at);
create trigger companies_set_updated    before update on public.companies    for each row execute function extensions.moddatetime(updated_at);
create trigger deals_set_updated        before update on public.deals        for each row execute function extensions.moddatetime(updated_at);
create trigger activities_set_updated   before update on public.activities   for each row execute function extensions.moddatetime(updated_at);
create trigger pupilos_set_updated      before update on public.pupilos      for each row execute function extensions.moddatetime(updated_at);

-- ═══════════════════════════════════════════════════════════════════
-- HELPER FUNCTIONS (security definer)
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select exists(
    select 1 from public.consultants
    where auth_user_id = auth.uid() and is_admin = true
  );
$$;

create or replace function public.my_consultant_id()
returns uuid
language sql
stable
security definer
set search_path = public, auth
as $$
  select id from public.consultants where auth_user_id = auth.uid() limit 1;
$$;

comment on function public.is_admin() is 'true si auth.uid() pertenece a un consultant con is_admin=true. Usado en RLS policies.';
comment on function public.my_consultant_id() is 'Devuelve el consultant.id del usuario autenticado actual.';

-- ═══════════════════════════════════════════════════════════════════
-- ROW LEVEL SECURITY
-- Modelo MVP: SELECT abierto a autenticados (filtrado en cliente),
-- INSERT/UPDATE/DELETE restringido. Endurecimiento per-consultor en F15.4.
-- ═══════════════════════════════════════════════════════════════════
alter table public.consultants   enable row level security;
alter table public.clients       enable row level security;
alter table public.companies     enable row level security;
alter table public.deals         enable row level security;
alter table public.activities    enable row level security;
alter table public.pupilos       enable row level security;
alter table public.activity_log  enable row level security;

-- ── CONSULTANTS ────────────────
create policy "consultants select all auth"   on public.consultants for select using (auth.uid() is not null);
create policy "consultants insert admin"       on public.consultants for insert with check (public.is_admin());
create policy "consultants update admin/self"  on public.consultants for update using (public.is_admin() or auth_user_id = auth.uid());
create policy "consultants delete admin"       on public.consultants for delete using (public.is_admin());

-- ── CLIENTS / COMPANIES / PUPILOS (admin escribe) ─────
create policy "clients select all auth"   on public.clients   for select using (auth.uid() is not null);
create policy "clients write admin"        on public.clients   for all    using (public.is_admin()) with check (public.is_admin());

create policy "companies select all auth" on public.companies for select using (auth.uid() is not null);
create policy "companies write admin"      on public.companies for all    using (public.is_admin()) with check (public.is_admin());

create policy "pupilos select all auth"   on public.pupilos   for select using (auth.uid() is not null);
create policy "pupilos write admin"        on public.pupilos   for all    using (public.is_admin()) with check (public.is_admin());

-- ── DEALS (admin escribe; en F15.4 se abrirá a consultor con split) ──
create policy "deals select all auth"     on public.deals     for select using (auth.uid() is not null);
create policy "deals write admin"          on public.deals     for all    using (public.is_admin()) with check (public.is_admin());

-- ── ACTIVITIES (consultor escribe las suyas) ──────────
create policy "activities select all auth" on public.activities for select using (auth.uid() is not null);
create policy "activities insert own/admin" on public.activities for insert
  with check (public.is_admin() or created_by = public.my_consultant_id());
create policy "activities update own/admin" on public.activities for update
  using  (public.is_admin() or created_by = public.my_consultant_id())
  with check (public.is_admin() or created_by = public.my_consultant_id());
create policy "activities delete own/admin" on public.activities for delete
  using (public.is_admin() or created_by = public.my_consultant_id());

-- ── ACTIVITY_LOG (insert por cualquiera, lectura sólo admin) ──
create policy "activity_log insert auth"  on public.activity_log for insert with check (auth.uid() is not null);
create policy "activity_log select admin" on public.activity_log for select using (public.is_admin());

-- ═══════════════════════════════════════════════════════════════════
-- REALTIME
-- Habilitar postgres_changes sólo en tablas de alta frecuencia.
-- ═══════════════════════════════════════════════════════════════════
alter publication supabase_realtime add table public.deals;
alter publication supabase_realtime add table public.activities;
alter publication supabase_realtime add table public.clients;

-- ═══════════════════════════════════════════════════════════════════
-- METADATA
-- ═══════════════════════════════════════════════════════════════════
comment on schema public is 'CEO Advisors CRM — schema 2026.05.1 — initial migration 2026-05-10';
