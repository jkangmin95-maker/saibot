-- 우리사이 v11.1 scheduler: call the imweb-poll Edge Function every minute (pg_cron + pg_net, both on the free tier).
-- Run in the Supabase SQL editor AFTER: supabase_migration_v11_1_imweb.sql, tokens seeded, Edge Function deployed,
-- and the function secret IMWEB_POLL_SECRET set. Not part of the local tests (no pg_cron / pg_net locally).
--
-- 0) Dashboard → Database → Extensions: enable pg_cron and pg_net (or run the two lines below).
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- 1) Store the same random value you set as the function secret IMWEB_POLL_SECRET (run once; never commit the value):
--      select vault.create_secret('<same value as IMWEB_POLL_SECRET>', 'imweb_poll_secret', 'imweb-poll shared secret');
--    To rotate later: select vault.update_secret((select id from vault.secrets where name = 'imweb_poll_secret'), '<new>');

-- 2) Schedule (re-running replaces the job of the same name).
select cron.schedule('imweb-poll', '* * * * *', $job$
  select net.http_post(
    url := 'https://iyligsrpaxitlpuwbdjx.supabase.co/functions/v1/imweb-poll',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-imweb-poll-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'imweb_poll_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 25000);
$job$);

-- Check:   select jobid, schedule, active from cron.job where jobname = 'imweb-poll';
--          select status_code, created from net._http_response order by created desc limit 5;   (no bodies with buyer data)
-- Pause:   update cron.job set active = false where jobname = 'imweb-poll';
-- Remove:  select cron.unschedule('imweb-poll');
