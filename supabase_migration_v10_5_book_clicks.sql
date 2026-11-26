-- 우리사이 v10.5: 책 링크 클릭 수 (고마움 카드 구절 아래 / 설정 맨 아래). 링크별 하루 클릭 수만 센다.
-- Run AFTER supabase_migration_v10_4_gratitude.sql. Safe to run more than once.
-- Rollback: supabase_migration_v10_5_book_clicks_down.sql   Tests: scripts/test_v10_5.sql
--
-- What is stored
-- * private.book_clicks: link_key ('card' | 'settings'), day (Asia/Seoul date), clicks. No user id, no couple code.
-- * private.book_click_caps: today's per-person call counter, keyed by md5(user id || KST date). Only today's rows
--   are kept (older rows are deleted on every call), and the row does not say which link was clicked.
--
-- Security model
-- * Both tables live in schema private (no usage for anon/authenticated), RLS on, no policies, no grants.
-- * public.log_book_click(p_key): SECURITY DEFINER, search_path pinned, execute for authenticated only.
--   Rejects unknown keys. Counts at most 20 clicks per person per KST day (both links together);
--   calls over the cap return false and change nothing.

begin;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.book_clicks (
  link_key text not null check (link_key in ('card', 'settings')),
  day date not null,
  clicks integer not null default 0 check (clicks >= 0),
  primary key (link_key, day)
);
alter table private.book_clicks enable row level security;
revoke all on table private.book_clicks from public, anon, authenticated;

create table if not exists private.book_click_caps (
  k text primary key,
  day date not null,
  n integer not null default 0
);
alter table private.book_click_caps enable row level security;
revoke all on table private.book_click_caps from public, anon, authenticated;

create or replace function public.log_book_click(p_key text)
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_day date := (now() at time zone 'Asia/Seoul')::date;
  v_n integer;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_key is null or p_key not in ('card', 'settings') then raise exception 'bad_key' using errcode = '22023'; end if;

  delete from private.book_click_caps where day < v_day;
  insert into private.book_click_caps as c (k, day, n) values (md5(v_uid::text || ':' || v_day::text), v_day, 1)
  on conflict (k) do update set n = c.n + 1
  returning n into v_n;
  if v_n > 20 then return false; end if;

  insert into private.book_clicks as b (link_key, day, clicks) values (p_key, v_day, 1)
  on conflict (link_key, day) do update set clicks = b.clicks + 1;
  return true;
end
$fn$;

revoke all on function public.log_book_click(text) from public, anon, authenticated;
grant execute on function public.log_book_click(text) to authenticated;

commit;
notify pgrst, 'reload schema';

-- Reading the numbers (SQL editor, as postgres):
--   select day, link_key, clicks from private.book_clicks order by day desc, link_key;
