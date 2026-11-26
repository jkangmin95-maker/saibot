-- Rollback for supabase_migration_v10_5_book_clicks.sql. Deletes all book link click counts.
begin;
drop function if exists public.log_book_click(text);
drop table if exists private.book_clicks;
drop table if exists private.book_click_caps; -- only exists if an earlier draft was applied
-- schema private is left in place (v9 / v10 / v10.4 use it).
commit;
notify pgrst, 'reload schema';
