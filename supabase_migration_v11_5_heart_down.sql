-- Rollback for supabase_migration_v11_5_heart.sql: restores the v11.3 public.submit_temp (gratitude-days without hearts),
-- drops the heart RPCs and private.mission_hearts (all sent hearts are deleted). Safe to run more than once.
begin;
drop function if exists public.send_heart(text);
drop function if exists public.my_heart_notices();
drop function if exists private.heart_candidates(text, uuid);
-- v11.3 submit_temp, verbatim (it must not reference private.mission_hearts any more)
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

drop table if exists private.mission_hearts;
commit;
notify pgrst, 'reload schema';
