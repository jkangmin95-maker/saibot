-- Down for supabase_auth_hook_v11_10_1.sql. First disable the hook in Dashboard > Authentication > Hooks
-- (and turn the Email provider off again), otherwise GoTrue calls a missing function on every signup.
drop function if exists public.hook_before_user_created(jsonb);
