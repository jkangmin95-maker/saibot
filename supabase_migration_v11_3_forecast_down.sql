-- Rollback for supabase_migration_v11_3_forecast.sql. Deletes all 우리 사이 예보 answers.
begin;
drop function if exists public.submit_forecast(integer, smallint[]);
drop function if exists public.my_forecast(integer);
drop table if exists public.forecast_answers;
drop function if exists public.forecast_answered(text, integer);
commit;
notify pgrst, 'reload schema';
