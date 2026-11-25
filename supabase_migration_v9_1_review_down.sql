-- Rollback for supabase_migration_v9_1_review.sql: restores the v9 state exactly.
begin;

-- 3) back to the v9 gemini_json (no global cap), then drop the usage table
-- private.gemini_json(body): POST body to Gemini, trying two models. Returns the parsed JSON
-- object from the first candidate, or null. Never raises.
create or replace function private.gemini_json(p_body jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, vault, extensions
as $fn$
declare
  v_key text;
  v_model text;
  v_resp extensions.http_response;
  v_text text;
  v_parsed jsonb;
  v_started timestamptz := clock_timestamp();
begin
  select decrypted_secret into v_key
  from vault.decrypted_secrets
  where name = 'urisai_gemini_api_key'
  limit 1;
  if v_key is null or length(v_key) = 0 then
    return null;
  end if;

  -- 503 "high demand" usually comes back fast, so flash-lite gets a second try.
  foreach v_model in array array['gemini-3.5-flash-lite', 'gemini-3.1-flash-lite', 'gemini-3.5-flash-lite', 'gemini-3.5-flash'] loop
    -- stay inside the 24s statement_timeout (each attempt <= 8s)
    exit when clock_timestamp() - v_started > interval '12 seconds';
    begin
      perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '8');
      perform extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT', '3');
      select * into v_resp
      from extensions.http((
        'POST',
        'https://generativelanguage.googleapis.com/v1beta/models/' || v_model || ':generateContent',
        array[extensions.http_header('x-goog-api-key', v_key)],
        'application/json',
        p_body::text
      )::extensions.http_request);

      if v_resp.status = 200 and v_resp.content is not null then
        v_text := btrim(coalesce(v_resp.content::jsonb #>> '{candidates,0,content,parts,0,text}', ''));
        v_text := regexp_replace(v_text, '^```(?:json)?\s*', '');
        v_text := regexp_replace(v_text, '\s*```$', '');
        if length(v_text) > 0 then
          v_parsed := v_text::jsonb;
          if jsonb_typeof(v_parsed) = 'object' then
            return v_parsed;
          end if;
        end if;
      end if;
    exception when others then
      -- timeout / 503 / bad JSON: try the next model
      null;
    end;
  end loop;
  return null;
exception when others then
  return null;
end;
$fn$;
revoke all on function private.gemini_json(jsonb) from public, anon, authenticated;

drop table if exists private.gemini_usage;

-- 2)
drop function if exists public.accept_mission(text);
-- (if step 2b was run:)  grant update (warmth_temp, completed_count) on public.couples to authenticated;

-- 1)
grant select on public.secret_emotions to authenticated;
drop policy if exists "emotions_member_select" on public.secret_emotions;
create policy "emotions_member_select" on public.secret_emotions for select to authenticated
  using (public.is_couple_member(couple_code));

commit;

notify pgrst, 'reload schema';
