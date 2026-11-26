-- Rollback for supabase_migration_v11_1_imweb.sql. Run supabase_cron_v11_1_imweb.sql's unschedule line FIRST.
-- Deletes the stored 아임웹 tokens and the processed-order log. Entitlements stay as they are; any row with
-- paid_source = 'imweb' is relabeled 'manual' (still paid, payment_ref kept) so the v11 check constraint can come back.
begin;
drop function if exists public.imweb_poll_finish(uuid, text);
drop function if exists public.imweb_poll_apply(uuid, bigint, text, text, text);
drop function if exists public.imweb_poll_save_tokens(uuid, text, text, text);
drop function if exists public.imweb_poll_lease(integer);
drop function if exists private.imweb_seed_tokens(text, text);
drop table if exists private.imweb_order_items;
drop table if exists private.imweb_oauth;
update private.couple_entitlements set paid_source = 'manual', updated_at = now() where paid_source = 'imweb';
alter table private.couple_entitlements drop constraint if exists couple_entitlements_paid_source_check;
alter table private.couple_entitlements add constraint couple_entitlements_paid_source_check
  check (paid_source in ('manual', 'portone', 'inicis', 'payapp'));
commit;
