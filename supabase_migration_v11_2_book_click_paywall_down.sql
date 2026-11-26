-- Rollback for supabase_migration_v11_2_book_click_paywall.sql: back to the v10.5 keys ('card' | 'settings').
-- Deletes the 'paywall' click counts (the v10.5 check constraint cannot hold them).
begin;

delete from private.book_clicks where link_key = 'paywall';
alter table private.book_clicks drop constraint if exists book_clicks_link_key_check;
alter table private.book_clicks add constraint book_clicks_link_key_check check (link_key in ('card', 'settings'));

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
