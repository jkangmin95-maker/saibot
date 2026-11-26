-- Rollback for supabase_migration_v11_3_temp.sql. Deletes all 우리사이 온도 answers/measurements and all self missions.
-- Also removes the old 예보 draft objects if they exist. schema private stays (v9 / v10 / v10.4 use it).
begin;
drop function if exists public.accept_self_mission(text);
drop function if exists public.my_self_missions();
drop function if exists public.create_self_mission();
drop function if exists public.submit_temp(smallint[]);
drop function if exists public.my_temp();
drop function if exists private.self_mission_json(private.self_missions, text);
drop function if exists private.temp_areas_json(numeric[]);
drop table if exists private.self_missions;
drop table if exists private.temp_measurements;
drop table if exists private.temp_answers;
drop table if exists private.temp_config;
drop function if exists public.submit_forecast(integer, smallint[]);
drop function if exists public.my_forecast(integer);
drop function if exists public.forecast_answered(text, integer);
drop table if exists public.forecast_answers;
commit;
notify pgrst, 'reload schema';
