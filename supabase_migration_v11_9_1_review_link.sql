-- v11.9.1 no-login review link: room for a review-only TEST couple in private.review_users. Down: supabase_migration_v11_9_1_review_link_down.sql
-- * review_users.kind: 'owner' (the existing owner row, Kakao) or 'test' (the two email/password test accounts).
-- * At most 1 owner and at most 2 test rows (owner + 2 test = 3 rows max), enforced in the database, not only in a seed.
-- * The test accounts and their couple are created by a generated seed that lives outside the repo
--   (scripts/make_review_link.py -> /workspace/secrets/review-link-seed.sql). No user id, email, hash or password in this file.
-- * No change to am_reviewer / review_reset / is_reviewer or to any grant: test accounts get exactly the owner's four reset buttons,
--   and review_reset still only touches the caller's own couple.
set client_encoding = 'UTF8';

alter table private.review_users add column if not exists kind text not null default 'owner';
do $$ begin
  alter table private.review_users add constraint review_users_kind_chk check (kind in ('owner', 'test'));
exception when duplicate_object then null; end $$;
create unique index if not exists review_users_one_owner on private.review_users ((kind)) where kind = 'owner';

create or replace function private.review_users_cap()
returns trigger
language plpgsql
set search_path = private, pg_temp
as $$
begin
  if new.kind = 'test' then
    perform pg_advisory_xact_lock(hashtext('private.review_users_cap'));
    if (select count(*) from private.review_users r where r.kind = 'test' and r.user_id <> new.user_id) >= 2 then
      raise exception 'review_users: at most 2 test accounts' using errcode = '23514';
    end if;
  end if;
  return new;
end
$$;
revoke all on function private.review_users_cap() from public, anon, authenticated;
drop trigger if exists review_users_cap on private.review_users;
create trigger review_users_cap before insert or update of kind on private.review_users
  for each row execute function private.review_users_cap();
