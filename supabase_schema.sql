-- Idempotent schema + grants for the 우리사이 PWA (anon REST access)

create table if not exists public.couples (
  code text primary key,
  warmth_temp numeric(4,1) not null default 37.5,
  completed_count integer not null default 2,
  created_at timestamptz not null default now()
);

create table if not exists public.daily_missions (
  id text primary key,
  couple_code text not null references public.couples(code) on delete cascade,
  target_role text not null check (target_role in ('A', 'B')),
  title text not null,
  message text not null,
  badge text not null default '오늘의 커플 추천 팁',
  accepted boolean not null default false,
  accepted_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.secret_emotions (
  id uuid primary key default gen_random_uuid(),
  couple_code text not null references public.couples(code) on delete cascade,
  author_role text not null check (author_role in ('A', 'B')),
  raw_text text not null,
  translated_mission_id text,
  created_at timestamptz not null default now()
);

alter table public.couples enable row level security;
alter table public.daily_missions enable row level security;
alter table public.secret_emotions enable row level security;

drop policy if exists "couples_anon_all" on public.couples;
drop policy if exists "missions_anon_all" on public.daily_missions;
drop policy if exists "emotions_anon_insert" on public.secret_emotions;

create policy "couples_anon_all" on public.couples for all using (true) with check (true);
create policy "missions_anon_all" on public.daily_missions for all using (true) with check (true);
create policy "emotions_anon_insert" on public.secret_emotions for insert with check (true);

grant usage on schema public to anon, authenticated, service_role;
grant select, insert, update, delete on public.couples to anon, authenticated, service_role;
grant select, insert, update, delete on public.daily_missions to anon, authenticated, service_role;
grant select, insert, update, delete on public.secret_emotions to anon, authenticated, service_role;

-- App uses REST polling, not postgres_changes. Publication add is optional and
-- ignored if the table is already a member.
do $$
begin
  begin
    alter publication supabase_realtime add table public.couples;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.daily_missions;
  exception when duplicate_object then null;
  end;
end $$;
