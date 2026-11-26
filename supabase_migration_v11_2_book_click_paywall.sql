-- 우리사이 v11.2: 책 링크 클릭 수에 결제 카드 링크('paywall', 플러스 30일권 카드 안 『긍정학개론』 보기)를 더한다.
-- Run AFTER supabase_migration_v10_5_book_clicks.sql. Safe to run more than once.
-- Rollback: supabase_migration_v11_2_book_click_paywall_down.sql   Tests: scripts/test_v11_2.sql
-- Same function as v10.5 (SECURITY DEFINER, search_path = public, pg_temp, execute for authenticated only); only the allowed
-- keys change: 'card' | 'settings' | 'paywall'. Still stores link_key + KST day + count only (no user id, no couple code).

begin;

alter table private.book_clicks drop constraint if exists book_clicks_link_key_check;
alter table private.book_clicks add constraint book_clicks_link_key_check check (link_key in ('card', 'settings', 'paywall'));

create or replace function public.log_book_click(p_key text)
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_key is null or p_key not in ('card', 'settings', 'paywall') then raise exception 'bad_key' using errcode = '22023'; end if;

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
