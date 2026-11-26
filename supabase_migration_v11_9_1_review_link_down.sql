-- Down for supabase_migration_v11_9_1_review_link.sql. Run the generated seed down
-- (/workspace/secrets/review-link-seed-down.sql) first to remove the test accounts and their couple.
-- Any 'test' rows still here are removed so they can't turn into owner-equivalent rows once the column is gone.
set client_encoding = 'UTF8';
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema = 'private' and table_name = 'review_users' and column_name = 'kind') then
    execute 'delete from private.review_users where kind = ''test''';
  end if;
end $$;
drop trigger if exists review_users_cap on private.review_users;
drop function if exists private.review_users_cap();
drop index if exists private.review_users_one_owner;
alter table private.review_users drop constraint if exists review_users_kind_chk;
alter table private.review_users drop column if exists kind;
