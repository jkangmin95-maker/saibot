-- Rollback for supabase_migration_v10_4_gratitude.sql. Deletes all gratitude send dates.
-- Warmth already added by send_gratitude stays in public.couples.warmth_temp (it is not recomputed).
begin;
drop function if exists public.send_gratitude();
drop table if exists private.gratitude_sends;
-- schema private is left in place (v9 / v10 use it).
commit;
notify pgrst, 'reload schema';
