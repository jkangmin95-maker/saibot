-- 우리사이 v10.4: 오늘의 고마움 카드. 보낸 "날"만 기록하고 다정함 온도를 올린다.
-- Run AFTER supabase_migration_v10_share_quiz.sql. Safe to run more than once.
-- Rollback: supabase_migration_v10_4_gratitude_down.sql   Tests: scripts/test_v10_4.sql
--
-- What is stored: couple_code + sender_role (A/B, needed for once-per-person-per-day) + sent_on (Asia/Seoul date).
-- The gratitude sentence is NEVER sent to or stored on the server (it goes straight to KakaoTalk via the phone's share sheet).
--
-- Security model
-- * private.gratitude_sends lives in schema private (no usage for anon/authenticated), RLS on, no policies, no grants.
-- * public.send_gratitude(): SECURITY DEFINER, search_path pinned, authenticated only. Takes no arguments: the couple
--   and the sender's role come from auth.uid(), so nobody can record for another couple.
-- * Idempotent: once per person per KST day (primary key). A repeat call the same day changes nothing.
--
-- Warmth (다정함 온도)
-- * missions done: +1.2 each (unchanged, accept_mission).
-- * first gratitude of the day per person: +0.3.
-- * bonus +0.2 when the couple's gratitude sends in the last 7 KST days (incl. this one) outnumber the 서운함 signals
--   sent in the same window (public.daily_missions rows, which are only created from 사이봇 비밀방 "신호 보내기").
--   Only counts are used; nothing reads public.secret_emotions. 서운함 never lowers the temperature.
-- * cap 45.0, like accept_mission.

begin;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.gratitude_sends (
  couple_code text not null references public.couples(code) on delete cascade,
  sender_role text not null check (sender_role in ('A', 'B')),
  sent_on date not null,
  primary key (couple_code, sender_role, sent_on)
);
alter table private.gratitude_sends enable row level security;
revoke all on table private.gratitude_sends from public, anon, authenticated;

create or replace function public.send_gratitude()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_day date := (now() at time zone 'Asia/Seoul')::date;
  c public.couples;
  v_role text;
  v_new integer := 0;
  v_grat integer := 0;
  v_sad integer := 0;
  v_prev numeric(4,1);
  v_add numeric(3,1) := 0;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into c from public.couples where user_a = v_uid or user_b = v_uid order by created_at limit 1 for update;
  if not found then raise exception 'couple_not_found' using errcode = 'P0002'; end if;
  v_role := case when c.user_a = v_uid then 'A' else 'B' end;
  v_prev := c.warmth_temp;

  insert into private.gratitude_sends(couple_code, sender_role, sent_on)
  values (c.code, v_role, v_day)
  on conflict do nothing;
  get diagnostics v_new = row_count;

  if v_new = 1 then
    select count(*) into v_grat from private.gratitude_sends
      where couple_code = c.code and sent_on > v_day - 7;
    select count(*) into v_sad from public.daily_missions
      where couple_code = c.code and created_at >= ((v_day - 6)::timestamp at time zone 'Asia/Seoul');
    v_add := 0.3 + case when v_grat > v_sad then 0.2 else 0 end;
    update public.couples set warmth_temp = least(45.0, warmth_temp + v_add)
      where code = c.code
      returning * into c;
  end if;

  return jsonb_build_object(
    'sent_today', true,
    'first_today', v_new = 1,
    'bump', c.warmth_temp - v_prev,
    'warmth_temp', c.warmth_temp,
    'completed_count', c.completed_count);
end
$fn$;
revoke all on function public.send_gratitude() from public, anon, authenticated;
grant execute on function public.send_gratitude() to authenticated;

commit;
notify pgrst, 'reload schema';
