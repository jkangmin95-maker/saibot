-- 우리사이 v11.5: 상대 미션 알림 + 하트 보내기 (partner heart).
-- Run AFTER supabase_migration_v11_3_temp.sql. Safe to run more than once. Rollback: supabase_migration_v11_5_heart_down.sql.
-- Tests: scripts/test_v11_5_heart.sql (scripts/run_local_sql_tests_v11_5_heart.sh). NOT applied to prod until Security reviews it.
--
-- What it does
-- * When one member completes a mission ("했어요": public.daily_missions.accepted by its target, or their own
--   private.self_missions.accepted), the OTHER current member sees a notice: {id, name, done_on, hearted}. Nothing else:
--   never the mission id, title, message, badge, source or which kind of mission it was (비밀방 privacy).
--   id = md5 of an internal key (opaque; only meaningful to public.send_heart).
-- * The partner may send one heart per mission (primary key). A heart never changes completion and never lowers anything.
-- * In public.submit_temp the heart counts as the SENDER's gratitude-day for the 고마움 area: same per-day unit as
--   private.gratitude_senders, deduped with a gratitude send on the same KST day, same grat_step / grat_cap. Only hearts
--   between the CURRENT two members count (sender_id and doer_id). submit_temp is otherwise byte-for-byte the v11.3 one.
--
-- Security model
-- * private.mission_hearts: schema private (no usage for anon/authenticated), RLS on, no policies, nothing granted.
-- * public.my_heart_notices() / public.send_heart(text): SECURITY DEFINER, search_path = public, pg_temp,
--   EXECUTE for authenticated only (revoked from PUBLIC and anon). Couple and partner come from auth.uid() + couples.user_a/b.
--   Only today's and yesterday's (KST) completions are listed or heartable; a member can never heart their own mission.
begin;

create table if not exists private.mission_hearts (
  mission_key text primary key,                      -- 'd:' || daily_missions.id  or  's:' || self_missions.id  (never returned)
  couple_code text not null references public.couples(code) on delete cascade,
  doer_id uuid not null references auth.users(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  sent_on date not null default ((now() at time zone 'Asia/Seoul')::date),
  created_at timestamptz not null default now(),
  check (doer_id <> sender_id)
);
create index if not exists mission_hearts_couple_sender on private.mission_hearts(couple_code, sender_id, sent_on);
alter table private.mission_hearts enable row level security;
revoke all on private.mission_hearts from public, anon, authenticated;

-- internal: the partner's completed missions of today / yesterday (KST) as (key, done_on). No content columns leave here.
create or replace function private.heart_candidates(p_code text, p_doer uuid)
returns table (mission_key text, done_on date)
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select 'd:' || m.id, (m.accepted_at at time zone 'Asia/Seoul')::date
    from public.daily_missions m
   where m.couple_code = p_code and m.accepted and m.accepted_at is not null and m.target_id = p_doer
     and (m.accepted_at at time zone 'Asia/Seoul')::date >= (now() at time zone 'Asia/Seoul')::date - 1
  union all
  select 's:' || s.id, (s.accepted_at at time zone 'Asia/Seoul')::date
    from private.self_missions s
   where s.couple_code = p_code and s.accepted and s.accepted_at is not null and s.user_id = p_doer
     and (s.accepted_at at time zone 'Asia/Seoul')::date >= (now() at time zone 'Asia/Seoul')::date - 1
$fn$;
revoke all on function private.heart_candidates(text, uuid) from public, anon, authenticated;

create or replace function public.my_heart_notices()
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
  v_name text;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into c from public.couples where user_a = v_uid or user_b = v_uid order by created_at limit 1;
  if not found then return '[]'::jsonb; end if;
  v_partner := case when c.user_a = v_uid then c.user_b else c.user_a end;
  if v_partner is null then return '[]'::jsonb; end if;
  v_name := left(coalesce(nullif(btrim(case when c.user_a = v_uid then c.name_b else c.name_a end), ''), '연인'), 20);
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', md5(x.mission_key), 'name', v_name, 'done_on', x.done_on,
                                        'hearted', h.mission_key is not null)
                     order by x.done_on desc, md5(x.mission_key))
      from private.heart_candidates(c.code, v_partner) x
      left join private.mission_hearts h on h.mission_key = x.mission_key and h.sender_id = v_uid
  ), '[]'::jsonb);
end
$fn$;
revoke all on function public.my_heart_notices() from public, anon, authenticated;
grant execute on function public.my_heart_notices() to authenticated;

create or replace function public.send_heart(p_id text)
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
  v_key text;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into c from public.couples where user_a = v_uid or user_b = v_uid order by created_at limit 1;
  if not found then raise exception 'couple_not_found' using errcode = 'P0002'; end if;
  v_partner := case when c.user_a = v_uid then c.user_b else c.user_a end;
  if v_partner is null or p_id is null or p_id !~ '^[0-9a-f]{32}$' then
    raise exception 'notice_not_found' using errcode = 'P0002';
  end if;
  select x.mission_key into v_key from private.heart_candidates(c.code, v_partner) x where md5(x.mission_key) = p_id limit 1;
  if v_key is null then raise exception 'notice_not_found' using errcode = 'P0002'; end if;
  insert into private.mission_hearts(mission_key, couple_code, doer_id, sender_id)
  values (v_key, c.code, v_partner, v_uid)
  on conflict (mission_key) do nothing;
  return public.my_heart_notices();
end
$fn$;
revoke all on function public.send_heart(text) from public, anon, authenticated;
grant execute on function public.send_heart(text) to authenticated;

-- submit_temp: v11.3 body, only the two gratitude-day counts now also include hearts
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
      -- v11.5: a heart sent for the partner's mission counts as that sender's gratitude-day (same day counted once)
      select count(*) into v_grat from (
        select g.user_id, g.sent_on from private.gratitude_senders g
         where g.couple_code = c.code and g.user_id in (v_uid, v_partner) and g.sent_on > v_start_day
        union
        select h.sender_id, h.sent_on from private.mission_hearts h
         where h.couple_code = c.code and h.sender_id in (v_uid, v_partner) and h.doer_id in (v_uid, v_partner) and h.sent_on > v_start_day
      ) gd;
    else
      v_start := greatest(c.created_at, now() - make_interval(days => cfg.first_window_days));
      v_start_day := (v_start at time zone 'Asia/Seoul')::date;
      select count(*) into v_grat from (
        select g.user_id, g.sent_on from private.gratitude_senders g
         where g.couple_code = c.code and g.user_id in (v_uid, v_partner) and g.sent_on >= v_start_day
        union
        select h.sender_id, h.sent_on from private.mission_hearts h
         where h.couple_code = c.code and h.sender_id in (v_uid, v_partner) and h.doer_id in (v_uid, v_partner) and h.sent_on >= v_start_day
      ) gd;
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

commit;
notify pgrst, 'reload schema';
