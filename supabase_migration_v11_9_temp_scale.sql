-- v11.9 temperature scale (proposal, Security review before apply). Down: supabase_migration_v11_9_temp_scale_down.sql
-- Answers today map to 32.0~42.0 (base 32 + span 10 x score/40), so the worst answers with a little activity show ~34.
-- New: base 30, span 13 -> answers map to 30.0~43.0; all-middle answers = 36.5; activity (+3.0 max, -0.5 min) can reach 45.
-- Config only: submit_temp/my_temp code unchanged; stored measurements are not recomputed (next measurement uses it).
set client_encoding = 'UTF8';
update private.temp_config set base = 30.0, span = 13.0 where id = 1;
