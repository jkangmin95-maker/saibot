-- 우리사이(Urisai) 실시간 2인 커플 동기화용 Supabase SQL 스키마
-- Supabase 대시보드 > SQL Editor에 전체 복사 후 [Run] 버튼을 누르세요.

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

-- 비밀 감정 기록은 본인 기기(localStorage)에만 보관하거나,
-- 서버 저장이 필요할 경우 아래 테이블에 Auth UID 기반 RLS를 적용합니다.
create table if not exists public.secret_emotions (
  id uuid primary key default gen_random_uuid(),
  couple_code text not null references public.couples(code) on delete cascade,
  author_role text not null check (author_role in ('A', 'B')),
  raw_text text not null,
  translated_mission_id text,
  created_at timestamptz not null default now()
);

-- 빠른 프로토타입 오픈용 익명 접근 정책 (정식 출시 시 Supabase Auth UID 정책으로 강화 권장)
alter table public.couples enable row level security;
alter table public.daily_missions enable row level security;
alter table public.secret_emotions enable row level security;

create policy "couples_anon_all" on public.couples for all using (true) with check (true);
create policy "missions_anon_all" on public.daily_missions for all using (true) with check (true);
create policy "emotions_anon_insert" on public.secret_emotions for insert with check (true);
