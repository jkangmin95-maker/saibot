-- v11.10.1 Before User Created auth hook: reject every new email-provider account (Kakao untouched).
-- The review test accounts are inserted by SQL (seed), which bypasses GoTrue, so they are not affected.
-- After apply: Dashboard > Authentication > Hooks > Before User Created -> public.hook_before_user_created,
-- enable it BEFORE turning on the Email provider. Down: supabase_auth_hook_v11_10_1_down.sql (disable the hook first).
create or replace function public.hook_before_user_created(event jsonb)
returns jsonb
language plpgsql
stable
set search_path = pg_catalog, pg_temp
as $$
begin
  if coalesce(event->'user'->'app_metadata'->>'provider', '') = 'email' then
    return jsonb_build_object('error', jsonb_build_object('http_code', 403, 'message', 'Email signup is disabled'));
  end if;
  return '{}'::jsonb;
end
$$;
revoke all on function public.hook_before_user_created(jsonb) from public, anon, authenticated;
grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
