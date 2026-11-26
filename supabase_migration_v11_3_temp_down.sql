-- Rollback for supabase_migration_v11_3_temp.sql. Deletes all 우리사이 온도 answers/measurements, self missions, mission sources
-- and the who-did-it id columns (daily_missions.sender_id/target_id, private.gratitude_senders).
-- Also removes the old 예보 draft objects if they exist. schema private stays (v9 / v10 / v10.4 use it).
begin;
drop trigger if exists temp_stamp_ids on public.daily_missions;
drop trigger if exists temp_stamp_user on private.gratitude_sends;
drop function if exists private.stamp_mission_ids();
drop function if exists private.stamp_gratitude_user();
drop function if exists public.send_secret_mission(text, text, text, text);
drop function if exists public.accept_self_mission(text);
drop function if exists public.my_self_missions();
drop function if exists public.create_self_mission();
drop function if exists public.submit_temp(smallint[]);
drop function if exists public.my_temp();
drop function if exists private.self_mission_json(private.self_missions, text);
drop function if exists private.temp_areas_json(numeric[]);
drop function if exists private.temp_take_floor_snapshot();
drop table if exists private.temp_floor_snapshot;
drop table if exists private.mission_sources;
drop table if exists private.self_missions;
alter table public.daily_missions drop column if exists sender_id;
alter table public.daily_missions drop column if exists target_id;
drop table if exists private.gratitude_senders;
drop table if exists private.temp_measurements;
drop table if exists private.temp_answers;
drop table if exists private.temp_config;
drop function if exists public.submit_forecast(integer, smallint[]);
drop function if exists public.my_forecast(integer);
drop function if exists public.forecast_answered(text, integer);
drop table if exists public.forecast_answers;
commit;
notify pgrst, 'reload schema';
