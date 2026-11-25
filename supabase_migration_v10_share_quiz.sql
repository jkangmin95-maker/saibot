-- 우리사이 v10: 우리 조합 카드 공유 동의 + 서로 맞히기 테스트(로그인 없음) + 퍼널 카운터.
-- Run AFTER supabase_migration_v9_1_review.sql. Safe to run more than once. Rollback: supabase_migration_v10_share_quiz_down.sql
-- Tests: scripts/test_v10.sql
--
-- Security model
-- * Every new table lives in schema private (no usage for anon/authenticated) AND has RLS on with no policies.
--   Nothing is granted on them to anon/authenticated; all access goes through the SECURITY DEFINER RPCs below,
--   which pin search_path.
-- * authenticated only: request_share_consent, respond_share_consent, my_share_consent (members of the couple only).
-- * anon + authenticated: create_quiz, get_quiz_for_guess, submit_quiz_guess, create_challenge, get_challenge_result, log_event.
--   - quiz/challenge tokens: 18 random bytes (pgcrypto gen_random_bytes), base64url, 24 chars; expire after 14 days.
--   - get_quiz_for_guess never returns the answers. submit_quiz_guess scores on the server and accepts ONE guess per quiz
--     (later calls return the stored score), so answers cannot be brute-forced through it.
--   - per-token read caps (quiz 200, challenge 600) + project-wide daily caps (Asia/Seoul day): 2000 quizzes,
--     2000 challenges, 4000 guesses, 60000 reads, 20000 events. Over a cap -> 'rate_limited'.
--   - nicknames: HTML tags and <>&"'` removed, trimmed, max 12 chars, must not be empty.
-- * Nothing here reads public.secret_emotions.
-- * Naming note: couples are keyed by code (text), so the couple column is couple_code, like daily_missions.

begin;

create extension if not exists pgcrypto with schema extensions;
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table if not exists private.share_consents (
  id uuid primary key default gen_random_uuid(),
  couple_code text not null references public.couples(code) on delete cascade,
  requested_by uuid not null,
  card_type text not null default 'combo' check (card_type in ('combo')),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  responded_at timestamptz
);
create index if not exists share_consents_couple_idx on private.share_consents(couple_code, card_type, created_at desc);

create table if not exists private.quiz_challenges (
  id bigint generated always as identity primary key,
  token text not null unique,
  source_quiz_id bigint not null unique,
  result_quiz_id bigint,
  read_count integer not null default 0,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '14 days'
);

create table if not exists private.quizzes (
  id bigint generated always as identity primary key,
  token text not null unique,
  a_name text not null,
  b_name text not null,
  answers smallint[] not null check (array_length(answers, 1) = 10),
  challenge_id bigint references private.quiz_challenges(id) on delete set null,
  guesses smallint[],
  score smallint,
  guessed_at timestamptz,
  read_count integer not null default 0,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '14 days'
);
do $$ begin
  alter table private.quiz_challenges add constraint quiz_challenges_source_fk
    foreign key (source_quiz_id) references private.quizzes(id) on delete cascade;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table private.quiz_challenges add constraint quiz_challenges_result_fk
    foreign key (result_quiz_id) references private.quizzes(id) on delete set null;
exception when duplicate_object then null; end $$;

create table if not exists private.anon_usage (
  day date not null,
  kind text not null,
  n integer not null default 0,
  primary key (day, kind)
);

create table if not exists private.funnel_events (
  id bigint generated always as identity primary key,
  event text not null,
  couple_code text,
  created_at timestamptz not null default now()
);
create index if not exists funnel_events_event_idx on private.funnel_events(event, created_at);

alter table private.share_consents enable row level security;
alter table private.quiz_challenges enable row level security;
alter table private.quizzes enable row level security;
alter table private.anon_usage enable row level security;
alter table private.funnel_events enable row level security;
revoke all on private.share_consents, private.quiz_challenges, private.quizzes, private.anon_usage, private.funnel_events
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Helpers (private, not callable by API roles)
-- ---------------------------------------------------------------------------
create or replace function private.new_token()
returns text language sql volatile set search_path = extensions, pg_temp as $$
  select translate(encode(extensions.gen_random_bytes(18), 'base64'), '+/=', '-_');
$$;

-- project-wide daily cap; raises rate_limited when the cap for this kind is reached
create or replace function private.bump_usage(p_kind text, p_cap integer)
returns void language plpgsql volatile security definer set search_path = private, pg_temp as $$
declare v_n integer;
begin
  insert into private.anon_usage as u(day, kind, n)
  values ((timezone('Asia/Seoul', now()))::date, p_kind, 1)
  on conflict (day, kind) do update set n = u.n + 1 where u.n < p_cap
  returning u.n into v_n;
  if v_n is null then raise exception 'rate_limited' using errcode = 'P0001'; end if;
end $$;

create or replace function private.clean_nick(p text)
returns text language sql immutable set search_path = pg_catalog as $$
  select nullif(left(btrim(regexp_replace(regexp_replace(coalesce(p, ''), '<[^>]*>', '', 'g'), '[<>&"''`\r\n\t]', '', 'g')), 12), '');
$$;

-- caller's couple row (member) or null
create or replace function private.my_couple_row()
returns public.couples language sql stable security definer set search_path = public, pg_temp as $$
  select c from public.couples c where auth.uid() is not null and (c.user_a = auth.uid() or c.user_b = auth.uid()) limit 1;
$$;

create or replace function private.challenge_json(p_ch private.quiz_challenges)
returns jsonb language plpgsql stable security definer set search_path = private, pg_temp as $$
declare s private.quizzes; r private.quizzes;
begin
  select * into s from private.quizzes where id = p_ch.source_quiz_id;
  if p_ch.result_quiz_id is not null then
    select * into r from private.quizzes where id = p_ch.result_quiz_id;
  end if;
  return jsonb_build_object(
    'status', case when r.id is null then 'waiting' else 'done' end,
    'a_name', s.a_name, 'b_name', s.b_name, 'score', s.score,
    'c_name', r.a_name, 'd_name', r.b_name, 'score2', r.score,
    'total', 10);
end $$;

revoke all on function private.new_token(), private.bump_usage(text, integer), private.clean_nick(text),
  private.my_couple_row(), private.challenge_json(private.quiz_challenges) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 우리 조합 카드: share consent (authenticated members only)
-- ---------------------------------------------------------------------------
create or replace function private.consent_json(p private.share_consents, p_couple public.couples)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select case when p.id is null then null else jsonb_build_object(
    'id', p.id,
    'card_type', p.card_type,
    'status', p.status,
    'requested_by_me', p.requested_by = auth.uid(),
    'requester_name', case when p.requested_by = p_couple.user_a then p_couple.name_a else p_couple.name_b end,
    'created_at', p.created_at,
    'responded_at', p.responded_at) end;
$$;
revoke all on function private.consent_json(private.share_consents, public.couples) from public, anon, authenticated;

-- my_share_consent(card_type): the latest consent row for the caller's couple, or null
create or replace function public.my_share_consent(p_card_type text default 'combo')
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare c public.couples; s private.share_consents;
begin
  if auth.uid() is null then return null; end if;
  c := private.my_couple_row();
  if c.code is null then return null; end if;
  select * into s from private.share_consents
    where couple_code = c.code and card_type = coalesce(p_card_type, 'combo')
    order by created_at desc, id limit 1;
  if not found then return null; end if;
  return private.consent_json(s, c);
end $$;

-- request_share_consent(card_type): ask the partner. Returns the existing row if one is pending or accepted.
-- After a decline a new request is allowed; max 5 requests per couple per day.
create or replace function public.request_share_consent(p_card_type text default 'combo')
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare c public.couples; s private.share_consents; v_type text := coalesce(p_card_type, 'combo'); v_today integer;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if v_type not in ('combo') then raise exception 'bad_card_type' using errcode = '22023'; end if;
  select * into c from public.couples where user_a = auth.uid() or user_b = auth.uid() limit 1 for update;
  if not found then raise exception 'not_in_couple' using errcode = 'P0002'; end if;
  if c.user_a is null or c.user_b is null then raise exception 'partner_not_joined' using errcode = 'P0001'; end if;
  select * into s from private.share_consents
    where couple_code = c.code and card_type = v_type
    order by created_at desc, id limit 1;
  if found and s.status in ('pending', 'accepted') then return private.consent_json(s, c); end if;
  select count(*) into v_today from private.share_consents
    where couple_code = c.code and created_at > now() - interval '1 day';
  if v_today >= 5 then raise exception 'rate_limited' using errcode = 'P0001'; end if;
  insert into private.share_consents(couple_code, requested_by, card_type)
    values (c.code, auth.uid(), v_type) returning * into s;
  return private.consent_json(s, c);
end $$;

-- respond_share_consent(id, accept): only the OTHER member of that couple may answer a pending request
create or replace function public.respond_share_consent(p_id uuid, p_accept boolean)
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare c public.couples; s private.share_consents;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into s from private.share_consents where id = p_id for update;
  if not found then raise exception 'consent_not_found' using errcode = 'P0002'; end if;
  select * into c from public.couples where code = s.couple_code;
  if not (c.user_a = auth.uid() or c.user_b = auth.uid()) then
    raise exception 'consent_not_found' using errcode = 'P0002';
  end if;
  if s.requested_by = auth.uid() then raise exception 'cannot_answer_own_request' using errcode = 'P0001'; end if;
  if s.status = 'pending' then
    update private.share_consents
      set status = case when p_accept then 'accepted' else 'declined' end, responded_at = now()
      where id = p_id returning * into s;
  end if;
  return private.consent_json(s, c);
end $$;

revoke all on function public.my_share_consent(text), public.request_share_consent(text),
  public.respond_share_consent(uuid, boolean) from public, anon;
grant execute on function public.my_share_consent(text), public.request_share_consent(text),
  public.respond_share_consent(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 서로 맞히기 테스트 (anon)
-- ---------------------------------------------------------------------------
-- create_quiz(my nickname, partner nickname, 10 answers 0..3, optional challenge token)
create or replace function public.create_quiz(p_a_name text, p_b_name text, p_answers integer[], p_challenge_token text default null)
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  v_a text := private.clean_nick(p_a_name);
  v_b text := private.clean_nick(p_b_name);
  v_ch private.quiz_challenges;
  v_token text;
  q private.quizzes;
begin
  if v_a is null or v_b is null then raise exception 'bad_nickname' using errcode = '22023'; end if;
  if p_answers is null or array_length(p_answers, 1) is distinct from 10 or array_ndims(p_answers) <> 1
     or exists (select 1 from unnest(p_answers) x where x is null or x < 0 or x > 3) then
    raise exception 'bad_answers' using errcode = '22023';
  end if;
  if p_challenge_token is not null and length(p_challenge_token) > 0 then
    if length(p_challenge_token) > 64 then raise exception 'link_expired' using errcode = 'P0001'; end if;
    select * into v_ch from private.quiz_challenges where token = p_challenge_token;
    if not found or v_ch.expires_at < now() then raise exception 'link_expired' using errcode = 'P0001'; end if;
  end if;
  perform private.bump_usage('quiz_create', 2000);
  loop
    v_token := private.new_token();
    exit when not exists (select 1 from private.quizzes where token = v_token);
  end loop;
  insert into private.quizzes(token, a_name, b_name, answers, challenge_id)
    values (v_token, v_a, v_b, p_answers::smallint[], v_ch.id) returning * into q;
  return jsonb_build_object('token', q.token, 'a_name', q.a_name, 'b_name', q.b_name, 'expires_at', q.expires_at);
end $$;

-- get_quiz_for_guess(token): names + status for the guesser. NEVER returns answers or guesses.
create or replace function public.get_quiz_for_guess(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare q private.quizzes; ch private.quiz_challenges;
begin
  if p_token is null or length(p_token) > 64 then raise exception 'link_expired' using errcode = 'P0001'; end if;
  select * into q from private.quizzes where token = p_token for update;
  if not found or q.expires_at < now() then raise exception 'link_expired' using errcode = 'P0001'; end if;
  if q.read_count >= 200 then raise exception 'rate_limited' using errcode = 'P0001'; end if;
  perform private.bump_usage('read', 60000);
  update private.quizzes set read_count = read_count + 1 where id = q.id;
  if q.challenge_id is not null then select * into ch from private.quiz_challenges where id = q.challenge_id; end if;
  return jsonb_build_object(
    'a_name', q.a_name, 'b_name', q.b_name, 'total', 10,
    'status', case when q.score is null then 'open' else 'done' end,
    'score', q.score,
    'has_challenge', q.challenge_id is not null,
    'challenge', case when q.score is not null and ch.id is not null and ch.result_quiz_id = q.id then private.challenge_json(ch) end,
    'my_challenge_token', (select token from private.quiz_challenges where source_quiz_id = q.id and q.score is not null));
end $$;

-- submit_quiz_guess(token, guesses): scores on the server. One guess per quiz; later calls return the stored score.
create or replace function public.submit_quiz_guess(p_token text, p_guesses integer[])
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare q private.quizzes; ch private.quiz_challenges; v_score integer;
begin
  if p_token is null or length(p_token) > 64 then raise exception 'link_expired' using errcode = 'P0001'; end if;
  select * into q from private.quizzes where token = p_token for update;
  if not found or q.expires_at < now() then raise exception 'link_expired' using errcode = 'P0001'; end if;
  if q.score is null then
    if p_guesses is null or array_length(p_guesses, 1) is distinct from 10 or array_ndims(p_guesses) <> 1
       or exists (select 1 from unnest(p_guesses) x where x is null or x < 0 or x > 3) then
      raise exception 'bad_answers' using errcode = '22023';
    end if;
    perform private.bump_usage('guess', 4000);
    select count(*) into v_score from generate_subscripts(q.answers, 1) i where q.answers[i] = p_guesses[i];
    update private.quizzes set guesses = p_guesses::smallint[], score = v_score, guessed_at = now()
      where id = q.id returning * into q;
    if q.challenge_id is not null then
      update private.quiz_challenges set result_quiz_id = q.id
        where id = q.challenge_id and result_quiz_id is null;
    end if;
  end if;
  if q.challenge_id is not null then select * into ch from private.quiz_challenges where id = q.challenge_id; end if;
  return jsonb_build_object(
    'a_name', q.a_name, 'b_name', q.b_name, 'score', q.score, 'total', 10,
    'challenge', case when ch.id is not null and ch.result_quiz_id = q.id then private.challenge_json(ch) end);
end $$;

-- create_challenge(quiz token): a link for a friend couple, tied to this (already scored) quiz. Idempotent per quiz.
create or replace function public.create_challenge(p_quiz_token text)
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare q private.quizzes; ch private.quiz_challenges; v_token text;
begin
  if p_quiz_token is null or length(p_quiz_token) > 64 then raise exception 'link_expired' using errcode = 'P0001'; end if;
  select * into q from private.quizzes where token = p_quiz_token for update;
  if not found or q.expires_at < now() then raise exception 'link_expired' using errcode = 'P0001'; end if;
  if q.score is null then raise exception 'quiz_not_finished' using errcode = 'P0001'; end if;
  select * into ch from private.quiz_challenges where source_quiz_id = q.id;
  if not found then
    perform private.bump_usage('challenge_create', 2000);
    loop
      v_token := private.new_token();
      exit when not exists (select 1 from private.quiz_challenges where token = v_token);
    end loop;
    insert into private.quiz_challenges(token, source_quiz_id) values (v_token, q.id) returning * into ch;
  end if;
  return jsonb_build_object('token', ch.token, 'score', q.score, 'expires_at', ch.expires_at);
end $$;

-- get_challenge_result(challenge token): waiting | done + both couples' names and scores (no answers)
create or replace function public.get_challenge_result(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare ch private.quiz_challenges;
begin
  if p_token is null or length(p_token) > 64 then raise exception 'link_expired' using errcode = 'P0001'; end if;
  select * into ch from private.quiz_challenges where token = p_token for update;
  if not found or ch.expires_at < now() then raise exception 'link_expired' using errcode = 'P0001'; end if;
  if ch.read_count >= 600 then raise exception 'rate_limited' using errcode = 'P0001'; end if;
  perform private.bump_usage('read', 60000);
  update private.quiz_challenges set read_count = read_count + 1 where id = ch.id;
  return private.challenge_json(ch);
end $$;

-- ---------------------------------------------------------------------------
-- Funnel counters
-- ---------------------------------------------------------------------------
-- log_event(event): whitelisted names only. couple_code is taken from the signed-in caller (never from the client).
-- Caps: 20000 events per day project-wide, 200 per couple per event per day.
create or replace function public.log_event(p_event text)
returns boolean language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare c public.couples; v_n integer;
begin
  if p_event is null or p_event not in ('combo_view', 'combo_share_request', 'combo_shared',
      'quiz_start', 'quiz_finish', 'challenge_sent', 'quiz_kakao_start') then
    return false;
  end if;
  c := private.my_couple_row();
  if c.code is not null then
    select count(*) into v_n from private.funnel_events
      where couple_code = c.code and event = p_event and created_at > now() - interval '1 day';
    if v_n >= 200 then return false; end if;
  end if;
  begin
    perform private.bump_usage('event', 20000);
  exception when others then
    return false;
  end;
  insert into private.funnel_events(event, couple_code) values (p_event, c.code);
  return true;
end $$;

revoke all on function public.create_quiz(text, text, integer[], text), public.get_quiz_for_guess(text),
  public.submit_quiz_guess(text, integer[]), public.create_challenge(text), public.get_challenge_result(text),
  public.log_event(text) from public;
grant execute on function public.create_quiz(text, text, integer[], text), public.get_quiz_for_guess(text),
  public.submit_quiz_guess(text, integer[]), public.create_challenge(text), public.get_challenge_result(text),
  public.log_event(text) to anon, authenticated;

commit;

notify pgrst, 'reload schema';

-- Funnel numbers (run as postgres in the SQL editor):
--   select event, count(*), count(distinct couple_code) couples from private.funnel_events
--   where created_at > now() - interval '7 days' group by 1 order by 1;
