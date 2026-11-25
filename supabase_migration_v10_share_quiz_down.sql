-- Rollback for supabase_migration_v10_share_quiz.sql. Deletes all v10 consent / quiz / funnel data.
begin;
drop function if exists public.log_event(text);
drop function if exists public.get_challenge_result(text);
drop function if exists public.create_challenge(text);
drop function if exists public.submit_quiz_guess(text, integer[]);
drop function if exists public.get_quiz_for_guess(text);
drop function if exists public.create_quiz(text, text, integer[], text);
drop function if exists public.respond_share_consent(uuid, boolean);
drop function if exists public.request_share_consent(text);
drop function if exists public.my_share_consent(text);
drop function if exists private.consent_json(private.share_consents, public.couples);
drop function if exists private.challenge_json(private.quiz_challenges);
drop function if exists private.my_couple_row();
drop function if exists private.clean_nick(text);
drop function if exists private.bump_usage(text, integer);
drop function if exists private.new_token();
alter table if exists private.quiz_challenges drop constraint if exists quiz_challenges_source_fk;
alter table if exists private.quiz_challenges drop constraint if exists quiz_challenges_result_fk;
drop table if exists private.quizzes;
drop table if exists private.quiz_challenges;
drop table if exists private.share_consents;
drop table if exists private.funnel_events;
drop table if exists private.anon_usage;
-- schema private and extension pgcrypto are left in place (v9 uses private; pgcrypto is a Supabase default).
commit;
notify pgrst, 'reload schema';
