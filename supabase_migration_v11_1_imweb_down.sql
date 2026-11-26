-- Rollback for supabase_migration_v11_1_imweb.sql. Run supabase_cron_v11_1_imweb.sql's unschedule line FIRST.
-- Deletes the stored 아임웹 tokens and the processed-order log. Passes and entitlements stay as they are; any pass with
-- source = 'imweb' (and entitlement with paid_source = 'imweb') is relabeled 'manual' (same days / paid_until, ref kept)
-- so the v11 check constraints can come back.
-- WARNING: private.imweb_oauth holds the ONLY live 아임웹 refresh token once the poller has rotated it (the box file is stale).
-- After this down, re-running the up needs a fresh token pair from the 아임웹 app authorize flow, not the old box file.
begin;
drop function if exists public.imweb_poll_finish(uuid, text);
drop function if exists public.imweb_poll_apply(uuid, bigint, text, text, text, integer);
drop function if exists public.imweb_poll_apply(uuid, bigint, text, text, text);
drop function if exists public.imweb_poll_save_tokens(uuid, text, text, text);
drop function if exists public.imweb_poll_lease(integer);
drop function if exists private.imweb_seed_tokens(text, text);
drop table if exists private.imweb_order_items;
drop table if exists private.imweb_oauth;
update private.couple_passes set source = 'manual' where source = 'imweb';
alter table private.couple_passes drop constraint if exists couple_passes_source_check;
alter table private.couple_passes add constraint couple_passes_source_check
  check (source in ('manual', 'portone', 'inicis', 'payapp'));
update private.couple_entitlements set paid_source = 'manual', updated_at = now() where paid_source = 'imweb';
alter table private.couple_entitlements drop constraint if exists couple_entitlements_paid_source_check;
alter table private.couple_entitlements add constraint couple_entitlements_paid_source_check
  check (paid_source in ('manual', 'portone', 'inicis', 'payapp'));
commit;
