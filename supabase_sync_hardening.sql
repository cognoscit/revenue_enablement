-- Revenue Enablement sync hardening for Supabase/PostgreSQL.
-- Safe phase: additive columns, indexes, triggers, audit table, diagnostics.
-- Run in Supabase SQL editor before relying on browser writes that omit updated_at.
-- Backup recommendation:
--   1. Export rg_sdm_deliverables and rg_sdm_config from Supabase.
--   2. Run this script in a maintenance window.
--   3. Validate duplicate/anomaly queries at the end before any cleanup.

create extension if not exists pgcrypto;

create or replace function public.rg_sdm_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.rg_sdm_bump_version()
returns trigger
language plpgsql
as $$
begin
  new.version = coalesce(old.version, 0) + 1;
  return new;
end;
$$;

alter table public.rg_sdm_deliverables
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists version bigint not null default 1,
  add column if not exists deleted_at timestamptz;

alter table public.rg_sdm_config
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists version bigint not null default 1;

create unique index if not exists rg_sdm_deliverables_id_uidx
  on public.rg_sdm_deliverables (id);

create unique index if not exists rg_sdm_config_id_uidx
  on public.rg_sdm_config (id);

create index if not exists rg_sdm_deliverables_date_idx
  on public.rg_sdm_deliverables (date_key desc);

create index if not exists rg_sdm_deliverables_member_idx
  on public.rg_sdm_deliverables (member_id);

create index if not exists rg_sdm_deliverables_updated_idx
  on public.rg_sdm_deliverables (updated_at desc);

create index if not exists rg_sdm_deliverables_deleted_idx
  on public.rg_sdm_deliverables (deleted_at)
  where deleted_at is not null;

drop trigger if exists trg_rg_sdm_deliverables_set_updated_at on public.rg_sdm_deliverables;
create trigger trg_rg_sdm_deliverables_set_updated_at
before update on public.rg_sdm_deliverables
for each row execute function public.rg_sdm_set_updated_at();

drop trigger if exists trg_rg_sdm_config_set_updated_at on public.rg_sdm_config;
create trigger trg_rg_sdm_config_set_updated_at
before update on public.rg_sdm_config
for each row execute function public.rg_sdm_set_updated_at();

drop trigger if exists trg_rg_sdm_deliverables_bump_version on public.rg_sdm_deliverables;
create trigger trg_rg_sdm_deliverables_bump_version
before update on public.rg_sdm_deliverables
for each row execute function public.rg_sdm_bump_version();

drop trigger if exists trg_rg_sdm_config_bump_version on public.rg_sdm_config;
create trigger trg_rg_sdm_config_bump_version
before update on public.rg_sdm_config
for each row execute function public.rg_sdm_bump_version();

create table if not exists public.rg_sdm_sync_audit (
  id uuid primary key default gen_random_uuid(),
  table_name text not null,
  row_id text not null,
  operation text not null check (operation in ('INSERT','UPDATE','DELETE')),
  old_row jsonb,
  new_row jsonb,
  changed_at timestamptz not null default now()
);

create index if not exists rg_sdm_sync_audit_row_idx
  on public.rg_sdm_sync_audit (table_name, row_id, changed_at desc);

create or replace function public.rg_sdm_audit_row()
returns trigger
language plpgsql
as $$
begin
  insert into public.rg_sdm_sync_audit(table_name, row_id, operation, old_row, new_row)
  values (
    tg_table_name,
    coalesce(new.id::text, old.id::text),
    tg_op,
    case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) else null end,
    case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) else null end
  );
  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_rg_sdm_deliverables_audit on public.rg_sdm_deliverables;
create trigger trg_rg_sdm_deliverables_audit
after insert or update or delete on public.rg_sdm_deliverables
for each row execute function public.rg_sdm_audit_row();

drop trigger if exists trg_rg_sdm_config_audit on public.rg_sdm_config;
create trigger trg_rg_sdm_config_audit
after insert or update or delete on public.rg_sdm_config
for each row execute function public.rg_sdm_audit_row();

-- Realtime prerequisite. If these commands fail with "already member", ignore.
alter publication supabase_realtime add table public.rg_sdm_deliverables;
alter publication supabase_realtime add table public.rg_sdm_config;

-- Diagnostics: duplicates by primary id. Should return zero rows.
select id, count(*) as rows_per_id
from public.rg_sdm_deliverables
group by id
having count(*) > 1;

-- Diagnostics: possible business duplicates. Review manually before cleanup.
select
  date_key,
  data->>'description' as description,
  data->>'memberId' as member_id,
  count(*) as possible_duplicates,
  array_agg(id order by updated_at desc) as ids
from public.rg_sdm_deliverables
where deleted_at is null
group by date_key, data->>'description', data->>'memberId'
having count(*) > 1;

-- Diagnostics: rows with invalid payloads. Should return zero rows.
select id, date_key, data
from public.rg_sdm_deliverables
where data is null
   or date_key is null
   or id is null;

-- Optional cleanup template, intentionally commented:
-- delete from public.rg_sdm_deliverables d
-- using (
--   select id, row_number() over (
--     partition by date_key, data->>'description', data->>'memberId'
--     order by updated_at desc
--   ) as rn
--   from public.rg_sdm_deliverables
--   where deleted_at is null
-- ) x
-- where d.id = x.id and x.rn > 1;
