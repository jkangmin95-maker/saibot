-- 우리사이 v11.3: 무료 "우리사이 온도" (두 사람이 따로 푸는 10문항 → 전체 온도 + 네 부분 온도) + 비밀방 글쓴이용 셀프 미션.
-- Run AFTER supabase_migration_v10_4_gratitude.sql (uses private.gratitude_sends). Safe to run more than once.
-- Replaces the never-applied "우리 사이 예보" draft (public.forecast_answers / my_forecast / submit_forecast are dropped).
-- Rollback: supabase_migration_v11_3_temp_down.sql. Tests: scripts/test_v11_3.sql (scripts/run_local_sql_tests_v11_3.sh)
--
-- Security model
-- * New tables live in schema private (also private.mission_sources, private.gratitude_senders) (no usage for anon/authenticated), RLS on, no policies, nothing granted:
--     private.temp_config        one row (id = 1): every weight / threshold of the formula
--     private.temp_answers       one row per (couple, user, round): 10 answers 0/1/2 + who the partner was at answer time
--     private.temp_measurements  one row per (couple, round): the two members + total + 4 area temperatures (the ONLY place
--                                a measured temperature is written; only public.submit_temp inserts here)
--     private.self_missions      the 비밀방 writer's own positive mission; only its owner ever reads it
-- * Every public function: SECURITY DEFINER, search_path = public, pg_temp, EXECUTE for authenticated only (not anon/PUBLIC).
--   The couple comes from auth.uid(); only the CURRENT two members (couples.user_a / user_b) are used, so a former partner's
--   answers, measurements or self missions are never read (re-pair safe).
-- * public.my_temp(): {status, days_left, next_on, last}. status: not_started | waiting | done (14-day limit not over).
--   last = null or {total, measured_on, areas: [{key, label, temp, why, todo} x4]}. Never returned: anyone's answers,
--   counts of gratitude / missions, where a mission came from.
-- * public.submit_temp(smallint[]): validates 10 answers in 0..2, raises too_soon inside the 14 days (server clock, KST days),
--   stores my answer for the current round; when the partner's answer for the same round (given with me as partner) exists,
--   scores and inserts the measurement. Couple row locked so two submits can't both miss each other.
-- * Formula (all numbers in private.temp_config):
--     per question both people: option 0/1/2 -> 2/1/0 points each, max 4.  area = base + span * points/max  (32.0 .. 42.0)
--     window = since this pair's last measurement (first time: last first_window_days days, not before the couple existed)
--     고마움 area  += min(grat_cap, grat_step * gratitude send-days in window)
--     책임 area    += min(mission_cap, mission_step * completed missions) - min(miss_cap, miss_step * missions not done
--                     grace_days after delivery). Missions = public.daily_missions of the couple + both members'
--                     private.self_missions, counted identically (source never used, never returned).
--     total = base + span * all points/40 + the same bonuses - penalty, clamped to [min_temp, max_temp], 1 decimal.
--     Only activity of the CURRENT two members counts (by user id, not couple_code + role): gratitude_senders.user_id,
--     daily_missions.sender_id + target_id (both must be one of the two), self_missions.user_id. These id columns are
--     stamped by triggers from auth.uid() / the seat at insert time and can't be changed by clients. Older rows (no ids)
--     are not counted; instead the FIRST measurement of a pair is floored at what home showed before this migration:
--     private.temp_floor_snapshot = couples.warmth_temp of every couple that existed when this file first ran (capped at
--     42.0, tied to the two members seated then). Taken ONCE (temp_config.floor_snapshot_at marker); a re-run adds
--     nothing. Live couples.warmth_temp (still member-writable) is never used for scoring; couples created later and
--     re-paired couples get no floor. warmth_temp is never written here.
-- * 비밀방 source: public.send_secret_mission() (the 신호 보내기 button) inserts the partner's mission and records
--     private.mission_sources(source = 'secret'), only if the couple used 사이봇 (sai_chat / generate_mission usage)
--     today or yesterday (KST). create_self_mission() requires such a 'secret' mission sent by the caller in the last
--     10 minutes. mission_sources is never used for scoring and never returned.
-- * Nothing here reads public.secret_emotions. No dynamic SQL.

begin;

-- old draft objects (예보)
drop function if exists public.submit_forecast(integer, smallint[]);
drop function if exists public.my_forecast(integer);
drop function if exists public.forecast_answered(text, integer);
drop table if exists public.forecast_answers;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.temp_config (
  id integer primary key default 1 check (id = 1),
  base numeric not null default 32.0,
  span numeric not null default 10.0 check (span > 0),
  grat_step numeric not null default 0.2 check (grat_step >= 0),
  grat_cap numeric not null default 1.5 check (grat_cap >= 0),
  mission_step numeric not null default 0.3 check (mission_step >= 0),
  mission_cap numeric not null default 1.5 check (mission_cap >= 0),
  miss_step numeric not null default 0.1 check (miss_step >= 0),
  miss_cap numeric not null default 0.5 check (miss_cap >= 0),
  grace_days integer not null default 3 check (grace_days between 0 and 30),
  interval_days integer not null default 14 check (interval_days between 1 and 60),
  first_window_days integer not null default 30 check (first_window_days between 1 and 365),
  min_temp numeric not null default 30.0,
  max_temp numeric not null default 45.0
);
alter table private.temp_config add column if not exists floor_cap numeric not null default 42.0;
alter table private.temp_config add column if not exists floor_snapshot_at timestamptz;
insert into private.temp_config(id) values (1) on conflict do nothing;

create table if not exists private.temp_answers (
  couple_code text not null references public.couples(code) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  partner_id uuid not null references auth.users(id) on delete cascade,
  round integer not null check (round between 1 and 100000),
  answers smallint[] not null check (
    array_ndims(answers) = 1 and cardinality(answers) = 10 and array_position(answers, null) is null
    and answers <@ array[0, 1, 2]::smallint[]),
  created_at timestamptz not null default now(),
  primary key (couple_code, user_id, round)
);

create table if not exists private.temp_measurements (
  couple_code text not null references public.couples(code) on delete cascade,
  round integer not null check (round between 1 and 100000),
  member_1 uuid not null,
  member_2 uuid not null,
  total numeric(4,1) not null,
  areas numeric(4,1)[] not null check (array_ndims(areas) = 1 and cardinality(areas) = 4),
  measured_at timestamptz not null default now(),
  primary key (couple_code, round),
  check (member_1 < member_2)
);
create index if not exists temp_measurements_pair on private.temp_measurements(couple_code, member_1, member_2, round desc);

create table if not exists private.self_missions (
  id text primary key,
  couple_code text not null references public.couples(code) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  message text not null,
  badge text not null default '오늘의 커플 추천 팁',
  accepted boolean not null default false,
  accepted_at timestamptz,
  created_at timestamptz not null default now(),
  created_on date not null default ((now() at time zone 'Asia/Seoul')::date),
  unique (couple_code, user_id, created_on)
);

create table if not exists private.temp_floor_snapshot (
  couple_code text primary key references public.couples(code) on delete cascade,
  member_1 uuid,
  member_2 uuid,
  floor numeric(4,1) not null,
  taken_at timestamptz not null default now()
);

create table if not exists private.mission_sources (
  mission_id text primary key references public.daily_missions(id) on delete cascade,
  couple_code text not null references public.couples(code) on delete cascade,
  sender_id uuid not null,
  source text not null check (source in ('secret')),
  created_at timestamptz not null default now()
);

-- who did it, by user id (re-pair safe counting). Stamped server-side; clients cannot set or change them.
-- gratitude_sends (v10.4) stays as is; who sent it lives in a side table filled by a trigger
create table if not exists private.gratitude_senders (
  couple_code text not null,
  sender_role text not null,
  sent_on date not null,
  user_id uuid not null,
  primary key (couple_code, sender_role, sent_on),
  foreign key (couple_code, sender_role, sent_on) references private.gratitude_sends(couple_code, sender_role, sent_on) on delete cascade on update cascade
);
alter table public.daily_missions add column if not exists sender_id uuid;
alter table public.daily_missions add column if not exists target_id uuid;

create or replace function private.stamp_gratitude_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
  if auth.uid() is not null then
    insert into private.gratitude_senders(couple_code, sender_role, sent_on, user_id)
    values (new.couple_code, new.sender_role, new.sent_on, auth.uid())
    on conflict do nothing;
  end if;
  return null;
end
$fn$;
drop trigger if exists temp_stamp_user on private.gratitude_sends;
create trigger temp_stamp_user after insert on private.gratitude_sends
  for each row execute function private.stamp_gratitude_user();

create or replace function private.stamp_mission_ids()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
  if tg_op = 'INSERT' then
    new.sender_id := auth.uid();
    new.target_id := (select case new.target_role when 'A' then c.user_a when 'B' then c.user_b end
                        from public.couples c where c.code = new.couple_code);
  else
    new.sender_id := old.sender_id;
    new.target_id := old.target_id;
  end if;
  return new;
end
$fn$;
drop trigger if exists temp_stamp_ids on public.daily_missions;
create trigger temp_stamp_ids before insert or update on public.daily_missions
  for each row execute function private.stamp_mission_ids();

alter table private.mission_sources enable row level security;
alter table private.temp_floor_snapshot enable row level security;
alter table private.gratitude_senders enable row level security;
alter table private.temp_config enable row level security;
alter table private.temp_answers enable row level security;
alter table private.temp_measurements enable row level security;
alter table private.self_missions enable row level security;
revoke all on table private.temp_config, private.temp_answers, private.temp_measurements, private.self_missions,
  private.mission_sources, private.gratitude_senders, private.temp_floor_snapshot from public, anon, authenticated;

-- one-time snapshot of what home shows today, for the first-measurement floor. Does nothing after the first run.
create or replace function private.temp_take_floor_snapshot()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_n integer := 0;
  v_cap numeric;
begin
  select floor_cap into v_cap from private.temp_config where id = 1 and floor_snapshot_at is null for update;
  if not found then return 0; end if;
  insert into private.temp_floor_snapshot(couple_code, member_1, member_2, floor)
  select c.code, least(c.user_a, c.user_b), greatest(c.user_a, c.user_b), round(least(v_cap, c.warmth_temp), 1)
    from public.couples c
   where c.warmth_temp is not null
  on conflict do nothing;
  get diagnostics v_n = row_count;
  update private.temp_config set floor_snapshot_at = now() where id = 1;
  return v_n;
end
$fn$;
revoke all on function private.temp_take_floor_snapshot() from public, anon, authenticated;
select private.temp_take_floor_snapshot();

-- area texts (『긍정학개론』). Order = app TEMP_QS themes: 1 고마움 (Q1-2), 2 그럴 수 있지 (Q3-5), 3 고정관념 내려놓기 (Q6-8), 4 책임 (Q9-10)
create or replace function private.temp_areas_json(p_temps numeric[])
returns jsonb
language sql
immutable
set search_path = public, pg_temp
as $fn$
  select jsonb_agg(jsonb_build_object('key', a.key, 'label', a.label, 'temp', p_temps[a.i], 'why', a.why, 'cite', a.cite, 'todo', a.todo) order by a.i)
  from (values
    (1, 'gratitude', '고마움', '감사하다고 말해야 감사한 것이 돼요. 마음은 말로 꺼낼 때 커져요.', null,
        '자기 전에 오늘 고마웠던 일 하나를 말로 전해 보기'),
    (2, 'okay', '그럴 수 있지', '서운한 감정은 떠오를 수 있지만, 붙잡는 건 선택이에요. "그럴 수 있지"는 나를 지키는 말이에요.', null,
        '서운한 순간이 오면 "그럴 수 있지"를 먼저 말해 보기'),
    (3, 'open', '고정관념 내려놓기', '괴로움은 "당연히 이래야지"라는 내 고정관념에서 시작돼요. 내려놓으면 다툴 일이 줄어요.', null,
        '"당연히"라는 말이 나오면 "그럴 수도 있지"로 바꿔 말해 보기'),
    (4, 'resp', '책임', '모든 것은 나로부터 비롯되고, 마음은 행동으로 증명돼요. 내가 먼저 하면 관계가 움직여요.', '도서 『긍정학개론』 중에서',
        '연인에게 바라는 것 하나를 내가 먼저 해 보기')
  ) as a(i, key, label, why, cite, todo)
$fn$;

create or replace function public.my_temp()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  c public.couples;
  v_partner uuid;
  cfg private.temp_config;
  last private.temp_measurements;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_next date;
  v_round integer;
  v_status text;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into c from public.couples where user_a = v_uid or user_b = v_uid order by created_at limit 1;
  if not found then raise exception 'couple_not_found' using errcode = 'P0002'; end if;
  v_partner := case when c.user_a = v_uid then c.user_b else c.user_a end;
  if v_partner is null then raise exception 'partner_not_joined' using errcode = 'P0001'; end if;
  select * into cfg from private.temp_config where id = 1;
  select * into last from private.temp_measurements m
   where m.couple_code = c.code and m.member_1 = least(v_uid, v_partner) and m.member_2 = greatest(v_uid, v_partner)
   order by m.round desc limit 1;
  if last.round is not null then
    v_next := (last.measured_at at time zone 'Asia/Seoul')::date + cfg.interval_days;
  end if;
  if v_next is not null and v_today < v_next then
    v_status := 'done';
  else
    select coalesce(max(round), 0) + 1 into v_round from private.temp_measurements where couple_code = c.code;
    v_status := case when exists (select 1 from private.temp_answers a where a.couple_code = c.code and a.user_id = v_uid
                                     and a.partner_id = v_partner and a.round = v_round)
                     then 'waiting' else 'not_started' end;
  end if;
  return jsonb_build_object(
    'status', v_status,
    'days_left', case when v_next is null then 0 else greatest(0, v_next - v_today) end,
    'next_on', case when v_next is null then null else to_char(v_next, 'YYYY-MM-DD') end,
    'last', case when last.round is null then null else jsonb_build_object(
       'total', last.total,
       'measured_on', to_char((last.measured_at at time zone 'Asia/Seoul')::date, 'YYYY-MM-DD'),
       'areas', private.temp_areas_json(last.areas::numeric[])) end);
end
$fn$;
revoke all on function public.my_temp() from public, anon, authenticated;
grant execute on function public.my_temp() to authenticated;

create or replace function public.submit_temp(p_answers smallint[])
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  c public.couples;
  v_partner uuid;
  cfg private.temp_config;
  last private.temp_measurements;
  theirs private.temp_answers;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_round integer;
  v_start timestamptz;
  v_start_day date;
  v_grat integer;
  v_done integer;
  v_miss integer;
  v_g numeric; v_m numeric; v_pen numeric;
  v_map constant integer[] := array[1, 1, 2, 2, 2, 3, 3, 3, 4, 4];
  v_pts integer[] := array[0, 0, 0, 0];
  v_max integer[] := array[0, 0, 0, 0];
  v_all integer := 0;
  v_p integer;
  v_areas numeric[] := array[0, 0, 0, 0];
  v_total numeric;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into c from public.couples where user_a = v_uid or user_b = v_uid order by created_at limit 1;
  if not found then raise exception 'couple_not_found' using errcode = 'P0002'; end if;
  if p_answers is null or array_ndims(p_answers) is distinct from 1 or cardinality(p_answers) <> 10
     or array_position(p_answers, null) is not null or not (p_answers <@ array[0, 1, 2]::smallint[]) then
    raise exception 'bad_answers' using errcode = '22023';
  end if;
  perform 1 from public.couples where code = c.code for update;
  v_partner := case when c.user_a = v_uid then c.user_b else c.user_a end;
  if v_partner is null then raise exception 'partner_not_joined' using errcode = 'P0001'; end if;
  select * into cfg from private.temp_config where id = 1;
  select * into last from private.temp_measurements m
   where m.couple_code = c.code and m.member_1 = least(v_uid, v_partner) and m.member_2 = greatest(v_uid, v_partner)
   order by m.round desc limit 1;
  if last.round is not null and v_today < (last.measured_at at time zone 'Asia/Seoul')::date + cfg.interval_days then
    raise exception 'too_soon' using errcode = 'P0001';
  end if;
  select coalesce(max(round), 0) + 1 into v_round from private.temp_measurements where couple_code = c.code;
  -- an unfinished answer given with a former partner is replaced; an answer with the current partner is kept as is
  delete from private.temp_answers
   where couple_code = c.code and user_id = v_uid and round = v_round and partner_id <> v_partner;
  insert into private.temp_answers(couple_code, user_id, partner_id, round, answers)
  values (c.code, v_uid, v_partner, v_round, p_answers)
  on conflict do nothing;

  select * into theirs from private.temp_answers a
   where a.couple_code = c.code and a.user_id = v_partner and a.partner_id = v_uid and a.round = v_round;
  if theirs.user_id is not null then
    p_answers := (select a.answers from private.temp_answers a where a.couple_code = c.code and a.user_id = v_uid and a.round = v_round);
    -- activity window
    if last.round is not null then
      v_start := last.measured_at;
      v_start_day := (v_start at time zone 'Asia/Seoul')::date;
      select count(*) into v_grat from private.gratitude_senders
       where couple_code = c.code and user_id in (v_uid, v_partner) and sent_on > v_start_day;
    else
      v_start := greatest(c.created_at, now() - make_interval(days => cfg.first_window_days));
      v_start_day := (v_start at time zone 'Asia/Seoul')::date;
      select count(*) into v_grat from private.gratitude_senders
       where couple_code = c.code and user_id in (v_uid, v_partner) and sent_on >= v_start_day;
    end if;
    -- missions: couple missions + both members' self missions, the same rule for both
    select count(*) filter (where done), count(*) filter (where missed) into v_done, v_miss from (
      select d.accepted and d.accepted_at > v_start and d.accepted_at <= now() as done,
             not d.accepted and d.created_at > v_start and d.created_at <= now() - make_interval(days => cfg.grace_days) as missed
        from public.daily_missions d where d.couple_code = c.code
         and d.sender_id in (v_uid, v_partner) and d.target_id in (v_uid, v_partner) and d.sender_id <> d.target_id
      union all
      select s.accepted and s.accepted_at > v_start and s.accepted_at <= now(),
             not s.accepted and s.created_at > v_start and s.created_at <= now() - make_interval(days => cfg.grace_days)
        from private.self_missions s where s.couple_code = c.code and s.user_id in (v_uid, v_partner)
    ) x;
    v_g := least(cfg.grat_cap, cfg.grat_step * v_grat);
    v_m := least(cfg.mission_cap, cfg.mission_step * v_done);
    v_pen := least(cfg.miss_cap, cfg.miss_step * v_miss);
    for i in 1..10 loop
      v_p := (2 - p_answers[i]) + (2 - theirs.answers[i]);
      v_all := v_all + v_p;
      v_pts[v_map[i]] := v_pts[v_map[i]] + v_p;
      v_max[v_map[i]] := v_max[v_map[i]] + 4;
    end loop;
    for k in 1..4 loop v_areas[k] := cfg.base + cfg.span * v_pts[k] / v_max[k]; end loop;
    v_areas[1] := v_areas[1] + v_g;
    v_areas[4] := v_areas[4] + v_m - v_pen;
    for k in 1..4 loop v_areas[k] := round(least(cfg.max_temp, greatest(cfg.min_temp, v_areas[k])), 1); end loop;
    v_total := round(least(cfg.max_temp, greatest(cfg.min_temp, cfg.base + cfg.span * v_all / 40.0 + v_g + v_m - v_pen)), 1);
    -- first measurement of this pair: never below what home showed at migration time (snapshot, same two members only)
    if last.round is null then
      v_total := greatest(v_total, coalesce((select f.floor from private.temp_floor_snapshot f
        where f.couple_code = c.code and f.member_1 = least(v_uid, v_partner) and f.member_2 = greatest(v_uid, v_partner)), 0));
    end if;
    insert into private.temp_measurements(couple_code, round, member_1, member_2, total, areas)
    values (c.code, v_round, least(v_uid, v_partner), greatest(v_uid, v_partner), v_total, v_areas)
    on conflict do nothing;
  end if;
  return public.my_temp();
end
$fn$;
revoke all on function public.submit_temp(smallint[]) from public, anon, authenticated;
grant execute on function public.submit_temp(smallint[]) to authenticated;

-- ---------- self missions: the 비밀방 writer's own positive mission ----------
create or replace function private.self_mission_json(s private.self_missions, p_role text)
returns jsonb
language sql
stable
set search_path = public, pg_temp
as $fn$
  select jsonb_build_object('id', s.id, 'couple_code', s.couple_code, 'target_role', p_role, 'title', s.title,
    'message', s.message, 'badge', s.badge, 'accepted', s.accepted, 'accepted_at', s.accepted_at, 'created_at', s.created_at)
$fn$;

-- Called by the writer's app right after a 비밀방 "신호 보내기" mission reached the partner.
-- Needs a couple mission for the partner created in the last 10 minutes. One per user per KST day (repeat -> same mission).
create or replace function public.create_self_mission()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  c public.couples;
  v_role text;
  v_n integer;
  v_k integer;
  s private.self_missions;
  v_title constant text[] := array[
    '오늘 "그럴 수 있지" 한 번 말해 보기',
    '고마운 일 하나 말로 전하기',
    '"당연히" 대신 "그럴 수도 있지"',
    '바라는 것 하나 내가 먼저 하기'];
  v_msg constant text[] := array[
    '서운한 마음이 떠오르면 붙잡기 전에 "그럴 수 있지"를 한 번 소리 내어 말해 보세요.',
    '감사하다고 말해야 감사한 것이 돼요. 오늘 연인에게 고마운 일 하나를 말로 전해 보세요.',
    '"당연히 ~해야지"가 떠오르면 "그럴 수도 있지"로 바꿔 말해 보세요.',
    '마음은 행동으로 증명돼요. 연인에게 바라는 것 하나를 오늘 내가 먼저 해 보세요.'];
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into c from public.couples where user_a = v_uid or user_b = v_uid order by created_at limit 1;
  if not found then raise exception 'couple_not_found' using errcode = 'P0002'; end if;
  if c.user_a is null or c.user_b is null then raise exception 'partner_not_joined' using errcode = 'P0001'; end if;
  v_role := case when c.user_a = v_uid then 'A' else 'B' end;
  -- the caller must have just sent a 비밀방 mission to the current partner (server-recorded source, not any mission)
  if not exists (select 1 from private.mission_sources ms join public.daily_missions d on d.id = ms.mission_id
                  where ms.couple_code = c.code and ms.source = 'secret' and ms.sender_id = v_uid
                    and d.target_id = case when v_role = 'A' then c.user_b else c.user_a end
                    and ms.created_at > now() - interval '10 minutes') then
    raise exception 'no_recent_mission' using errcode = 'P0001';
  end if;
  select * into s from private.self_missions where couple_code = c.code and user_id = v_uid
     and created_on = (now() at time zone 'Asia/Seoul')::date;
  if s.id is null then
    select count(*) into v_n from private.self_missions where couple_code = c.code and user_id = v_uid;
    v_k := (v_n % 4) + 1;
    insert into private.self_missions(id, couple_code, user_id, title, message)
    values (gen_random_uuid()::text, c.code, v_uid, v_title[v_k], v_msg[v_k])
    on conflict do nothing
    returning * into s;
    if s.id is null then
      select * into s from private.self_missions where couple_code = c.code and user_id = v_uid
         and created_on = (now() at time zone 'Asia/Seoul')::date;
    end if;
  end if;
  return private.self_mission_json(s, v_role);
end
$fn$;
revoke all on function public.create_self_mission() from public, anon, authenticated;
grant execute on function public.create_self_mission() to authenticated;

-- 사이봇 비밀방 "신호 보내기": the partner's mission + its source. Same row shape as the old direct insert.
create or replace function public.send_secret_mission(p_id text, p_title text, p_badge text, p_message text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  c public.couples;
  v_role text;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  d public.daily_missions;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into c from public.couples where user_a = v_uid or user_b = v_uid order by created_at limit 1;
  if not found then raise exception 'couple_not_found' using errcode = 'P0002'; end if;
  if c.user_a is null or c.user_b is null then raise exception 'partner_not_joined' using errcode = 'P0001'; end if;
  if p_id is null or p_id !~ '^m-[0-9]{10,16}$'
     or coalesce(length(btrim(p_title)), 0) not between 1 and 80
     or coalesce(length(btrim(p_message)), 0) not between 1 and 600
     or coalesce(length(p_badge), 0) > 40 then
    raise exception 'bad_mission' using errcode = '22023';
  end if;
  -- 사이봇 was used by this couple today / yesterday (KST): the mission draft came from 비밀방
  if not exists (select 1 from public.sai_chat_usage u where u.couple_code = c.code and u.day >= v_today - 1 and u.call_count > 0)
     and not exists (select 1 from public.mission_gen_usage u where u.couple_code = c.code and u.day >= v_today - 1 and u.call_count > 0) then
    raise exception 'no_saibot_use' using errcode = 'P0001';
  end if;
  v_role := case when c.user_a = v_uid then 'A' else 'B' end;
  insert into public.daily_missions(id, couple_code, target_role, title, badge, message, accepted)
  values (p_id, c.code, case when v_role = 'A' then 'B' else 'A' end, btrim(p_title),
          coalesce(nullif(btrim(p_badge), ''), '오늘의 커플 추천 팁'), btrim(p_message), false)
  returning * into d;
  insert into private.mission_sources(mission_id, couple_code, sender_id, source) values (d.id, c.code, v_uid, 'secret');
  return jsonb_build_object('id', d.id, 'target_role', d.target_role, 'created_at', d.created_at);
end
$fn$;
revoke all on function public.send_secret_mission(text, text, text, text) from public, anon, authenticated;
grant execute on function public.send_secret_mission(text, text, text, text) to authenticated;

-- the caller's own self missions in the current couple (newest 30). The partner never gets these.
create or replace function public.my_self_missions()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  c public.couples;
  v_role text;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into c from public.couples where user_a = v_uid or user_b = v_uid order by created_at limit 1;
  if not found then raise exception 'couple_not_found' using errcode = 'P0002'; end if;
  v_role := case when c.user_a = v_uid then 'A' else 'B' end;
  return coalesce((select jsonb_agg(private.self_mission_json(s, v_role) order by s.created_at desc)
    from (select * from private.self_missions where couple_code = c.code and user_id = v_uid
           order by created_at desc limit 30) s), '[]'::jsonb);
end
$fn$;
revoke all on function public.my_self_missions() from public, anon, authenticated;
grant execute on function public.my_self_missions() to authenticated;

-- mark my own self mission done (no warmth / count change: it only counts at the next measurement)
create or replace function public.accept_self_mission(p_id text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  c public.couples;
  s private.self_missions;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into c from public.couples where user_a = v_uid or user_b = v_uid order by created_at limit 1;
  if not found then raise exception 'couple_not_found' using errcode = 'P0002'; end if;
  if p_id is null or length(p_id) > 64 then raise exception 'mission_not_found' using errcode = 'P0002'; end if;
  update private.self_missions set accepted = true, accepted_at = now()
   where id = p_id and couple_code = c.code and user_id = v_uid and not accepted;
  select * into s from private.self_missions where id = p_id and couple_code = c.code and user_id = v_uid;
  if s.id is null then raise exception 'mission_not_found' using errcode = 'P0002'; end if;
  return private.self_mission_json(s, case when c.user_a = v_uid then 'A' else 'B' end);
end
$fn$;
revoke all on function public.accept_self_mission(text) from public, anon, authenticated;
grant execute on function public.accept_self_mission(text) to authenticated;

-- helpers in private: not callable by the API roles (no schema usage) and no EXECUTE either
revoke all on function private.temp_areas_json(numeric[]) from public, anon, authenticated;
revoke all on function private.self_mission_json(private.self_missions, text) from public, anon, authenticated;
revoke all on function private.stamp_gratitude_user() from public, anon, authenticated;
revoke all on function private.stamp_mission_ids() from public, anon, authenticated;

commit;
notify pgrst, 'reload schema';
