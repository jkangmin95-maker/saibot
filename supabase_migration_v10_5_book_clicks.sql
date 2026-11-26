-- 우리사이 v10.5: 책 링크 클릭 수 (고마움 카드 구절 아래 / 설정 맨 아래). 링크별 하루 클릭 수만 센다.
-- Run AFTER supabase_migration_v10_4_gratitude.sql. Safe to run more than once.
-- Rollback: supabase_migration_v10_5_book_clicks_down.sql   Tests: scripts/test_v10_5.sql
--
-- What is stored
-- * private.book_clicks: link_key ('card' | 'settings'), day (Asia/Seoul date), clicks. Nothing else:
--   no user id, no hashed id, no couple code. There is no per-person limit (privacy over exact counts),
--   so one person tapping many times can inflate a day's number.
--
-- Security model
-- * The table lives in schema private (no usage for anon/authenticated), RLS on, no policies, no grants.
-- * public.log_book_click(p_key): SECURITY DEFINER, search_path pinned, execute for authenticated only.
--   Requires a signed-in user (auth.uid()), rejects unknown keys, adds 1 to today's row for that link.

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

-- An earlier draft of this migration had a per-person counter table. Remove it if it was ever created.
drop table if exists private.book_click_caps;

create or replace function public.log_book_click(p_key text)
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_key is null or p_key not in ('card', 'settings') then raise exception 'bad_key' using errcode = '22023'; end if;

  insert into private.book_clicks as b (link_key, day, clicks)
  values (p_key, (now() at time zone 'Asia/Seoul')::date, 1)
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
