-- Rollback for supabase_migration_v11_paywall.sql. Deletes the paywall config and every couple's 결제 확인 코드 / paid flag.
-- Restores the v10 log_event (v10 events only). v10 tables and data are untouched.
begin;
drop function if exists public.my_report();
drop function if exists public.request_pay_code();
drop function if exists public.get_paywall_config();
drop function if exists private.set_couple_paid(text, boolean, text, text);
drop function if exists private.new_pay_code();
drop function if exists private.paywall_on();
drop table if exists private.couple_entitlements;
drop table if exists private.paywall_config;
create or replace function public.log_event(p_event text)
returns boolean language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare c public.couples; v_n integer;
begin
  if p_event is null or p_event not in ('combo_view', 'combo_share_request', 'combo_shared',
      'quiz_start', 'quiz_finish', 'challenge_sent', 'quiz_kakao_start') then
    return false;
  end if;
  c := private.my_couple_row();
  if c.code is not null then
    select count(*) into v_n from private.funnel_events
      where couple_code = c.code and event = p_event and created_at > now() - interval '1 day';
    if v_n >= 200 then return false; end if;
  end if;
  begin
    perform private.bump_usage('event', 20000);
  exception when others then
    return false;
  end;
  insert into private.funnel_events(event, couple_code) values (p_event, c.code);
  return true;
end $$;
revoke all on function public.log_event(text) from public;
grant execute on function public.log_event(text) to anon, authenticated;
commit;
notify pgrst, 'reload schema';
