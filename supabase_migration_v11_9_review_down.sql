-- v11.9 owner review mode: down. Removes only what the up created. Data it changed (deleted today's rows,
-- a moved measured_at for the owner's own pair) is not restored.
set client_encoding = 'UTF8';
drop function if exists public.review_reset(text);
drop function if exists public.am_reviewer();
drop function if exists private.is_reviewer(uuid);
drop table if exists private.review_users;
