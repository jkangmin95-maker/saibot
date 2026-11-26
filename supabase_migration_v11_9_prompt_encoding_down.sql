-- v11.9 prompt encoding repair: down = the exact live definitions captured 2026-11-27 01:58 KST (garbled, as they were).
set client_encoding = 'UTF8';

CREATE OR REPLACE FUNCTION public.sai_chat(couple_code text, messages jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'vault', 'extensions'
 SET statement_timeout TO '24s'
AS $function$
#variable_conflict use_column
declare
  v_code text;
  v_count integer;
  v_today date := (timezone('Asia/Seoul', now()))::date;
  v_msgs jsonb;
  v_n integer;
  v_last text;
  v_contents jsonb := '[]'::jsonb;
  v_item jsonb;
  v_role text;
  v_text text;
  v_prev_role text := '';
  v_i integer := 0;
  v_sys text;
  v_out jsonb;
  v_reply text;
  v_missions jsonb := '[]'::jsonb;
  v_m jsonb;
  v_report_on boolean := false;
begin
  if couple_code is null or length(btrim(couple_code)) = 0 or length(couple_code) > 32 then
    return null;
  end if;
  v_code := btrim(couple_code);
  if auth.uid() is null or not public.is_couple_member(v_code) then
    return null;
  end if;
  if messages is null or jsonb_typeof(messages) <> 'array' then
    return null;
  end if;

  v_n := jsonb_array_length(messages);
  if v_n = 0 then return null; end if;
  if messages -> (v_n - 1) ->> 'role' is distinct from 'user' then return null; end if;
  v_last := btrim(coalesce(messages -> (v_n - 1) ->> 'text', ''));
  if length(v_last) = 0 or length(v_last) > 500 then return null; end if;

  -- v11: ë¹„ë°€ë°© AI cost cap per user per KST day (private.secret_ai_daily_cap). Over it: no Gemini call, no topic key.
  if not private.take_secret_ai_call() then
    return jsonb_build_object('capped', true);
  end if;

  -- keep the last 10 turns
  select coalesce(jsonb_agg(e order by ord), '[]'::jsonb) into v_msgs
  from jsonb_array_elements(messages) with ordinality as t(e, ord)
  where ord > greatest(v_n - 10, 0);

  insert into public.sai_chat_usage as u(couple_code, day, call_count)
  values (v_code, v_today, 1)
  on conflict on constraint sai_chat_usage_pkey
  do update set call_count = u.call_count + 1
  where u.call_count < 60
  returning u.call_count into v_count;
  if v_count is null then
    return null;
  end if;

  -- v11: ì†ë§ˆìŒ ë¦¬í¬íŠ¸. ê¸°ëŠ¥ì´ ì¼œì ¸ ìžˆê³  ì´ ì‚¬ëžŒì´ [í™•ì¸í–ˆì–´ìš”]ë¥¼ ëˆ„ë¥¸ ë’¤ì¼ ë•Œë§Œ, ë°©ê¸ˆ ì“´ ë¬¸ìž¥ì„
  -- ê³ ì • ì£¼ì œ í‚¤ í•˜ë‚˜ë¡œ ë°”ê¿” ì €ìž¥í•œë‹¤(ë¬¸ìž¥ì€ ì €ìž¥í•˜ì§€ ì•ŠìŒ). êº¼ì ¸ ìžˆìœ¼ë©´ ì•„ë¬´ê²ƒë„ í•˜ì§€ ì•Šê³ , ì‹¤íŒ¨í•´ë„ ëŒ€í™”ì— ì˜í–¥ ì—†ìŒ.
  perform private.record_secret_topic(v_code, v_last);
  v_report_on := (private.paywall_on()).id is not null;

  -- build Gemini contents: must start with a user turn, roles must alternate
  for v_item in select e from jsonb_array_elements(v_msgs) as t(e) loop
    v_i := v_i + 1;
    v_role := case when v_item->>'role' = 'user' then 'user' else 'model' end;
    v_text := left(btrim(coalesce(v_item->>'text', '')), 500);
    continue when length(v_text) = 0;
    continue when v_prev_role = '' and v_role = 'model';
    if v_i = jsonb_array_length(v_msgs) then
      v_text := private.couple_context(v_code) || E'\n[ì§€ê¸ˆ ë©”ì‹œì§€] ' || v_text;
    end if;
    if v_role = v_prev_role then
      v_contents := jsonb_set(
        v_contents,
        array[(jsonb_array_length(v_contents) - 1)::text, 'parts', '0', 'text'],
        to_jsonb((v_contents -> -1 #>> '{parts,0,text}') || E'\n' || v_text));
    else
      v_contents := v_contents || jsonb_build_array(jsonb_build_object(
        'role', v_role, 'parts', jsonb_build_array(jsonb_build_object('text', v_text))));
    end if;
    v_prev_role := v_role;
  end loop;
  if jsonb_array_length(v_contents) = 0 then return null; end if;

  v_sys :=
    'ë„ˆëŠ” ì»¤í”Œ ê´€ê³„ ì½”ì¹­ ì•± ''ìš°ë¦¬ì‚¬ì´''ì˜ AI ì¹œêµ¬ ''ì‚¬ì´ë´‡''ì´ì•¼. ì§€ê¸ˆ ëŒ€í™”í•˜ëŠ” ì‚¬ëžŒì€ ''ë‚˜''ì´ê³ , ' ||
    -- v11: ì†ë§ˆìŒ ë¦¬í¬íŠ¸ê°€ ì¼œì ¸ ìžˆì„ ë•Œë§Œ ì•ˆë‚´ê°€ ë°”ë€ë‹¤. êº¼ì ¸ ìžˆìœ¼ë©´ v9.1ê³¼ ê¸€ìž í•˜ë‚˜ê¹Œì§€ ê°™ë‹¤.
    case when v_report_on
      then 'ì—¬ê¸° ì“´ ë¬¸ìž¥ì€ ì—°ì¸ì—ê²Œ ì ˆëŒ€ ë³´ì´ì§€ ì•Šì•„. ë‹¤ë§Œ ë¹„ë°€ë°© ì•ˆë‚´ì—ì„œ [í™•ì¸í–ˆì–´ìš”]ë¥¼ ëˆ„ë¥¸ ë’¤ì— ì“´ ê¸€ì€ ìš”ì¦˜ ë§ˆìŒì´ ì–´ëŠ ìª½ì— ìžˆëŠ”ì§€ë§Œ ì£¼ì œ(ì˜ˆ: ì—°ë½ ë¹ˆë„, ë§íˆ¬ ì„œìš´í•¨)ë¡œ ì •ë¦¬ë¼ì„œ ë‘ ì‚¬ëžŒì´ í•¨ê»˜ ì—¬ëŠ” ë¦¬í¬íŠ¸ì— ë“¤ì–´ê°ˆ ìˆ˜ ìžˆì–´. ì“´ ë¬¸ìž¥ ê·¸ëŒ€ë¡œë‚˜ ì¸ìš©ì€ ì ˆëŒ€ ë“¤ì–´ê°€ì§€ ì•Šì•„. ì´ ë¶€ë¶„ì„ ë¬¼ì–´ë³´ë©´ ì´ëŒ€ë¡œë§Œ ì„¤ëª…í•´.'
      else 'ì´ ë¹„ë°€ë°© ëŒ€í™”ëŠ” ì—°ì¸ì—ê²Œ ì ˆëŒ€ ë³´ì´ì§€ ì•Šì•„.' end || E'\n' ||
    'ì—­í• :' || E'\n' ||
    '- ìƒëŒ€ê°€ ë°©ê¸ˆ í•œ ë§ì— ì§ì ‘, êµ¬ì²´ì ìœ¼ë¡œ ë°˜ì‘í•´. ìƒëŒ€ê°€ ì“´ ë‹¨ì–´ì™€ ìƒí™©ì„ ì§šì–´ì„œ ë§í•´. ë»”í•œ ìœ„ë¡œ ë¬¸êµ¬ë‚˜ í…œí”Œë¦¿ ê°™ì€ ë§ ê¸ˆì§€.' || E'\n' ||
    '- ì¹œí•œ ì–¸ë‹ˆ/í˜•ì²˜ëŸ¼ ë”°ëœ»í•˜ê³  ìžì—°ìŠ¤ëŸ¬ìš´ í•œêµ­ì–´. ë°˜ë§ ê¸ˆì§€, í•­ìƒ ë¶€ë“œëŸ¬ìš´ í•´ìš”ì²´(~ìš”). 1~3ë¬¸ìž¥, ì§§ê²Œ. ì´ëª¨ì§€ëŠ” ê°€ë” í•˜ë‚˜ ì •ë„.' || E'\n' ||
    '- ì¸ì‚¬Â·ìž¡ë‹´Â·ì§ˆë¬¸ì´ë©´ ê·¸ì— ë§žê²Œ ìžì—°ìŠ¤ëŸ½ê²Œ ëŒ€ë‹µí•˜ê³ , í•„ìš”í•˜ë©´ ì˜¤ëŠ˜ ì—°ì¸ê³¼ ìžˆì—ˆë˜ ì¼ì„ ê°€ë³ê²Œ ë¬¼ì–´ë´.' || E'\n' ||
    '- ì„œìš´í•¨Â·ì•„ì‰¬ì›€Â·ë°”ëžŒì´ ë“œëŸ¬ë‚˜ë©´ ê³µê°í•œ ë’¤, ì—°ì¸ì—ê²Œ ''ì˜¤ëŠ˜ì˜ ë¯¸ì…˜''ìœ¼ë¡œ ìŠ¬ì© ë³´ë‚¼ ë‹¤ì •í•œ í–‰ë™ ì œì•ˆì„ 2ê°œ ë§Œë“¤ì–´.' || E'\n' ||
    '- ì •ë³´ê°€ ë¶€ì¡±í•˜ë©´ ë¯¸ì…˜ ì—†ì´ í•œ ê°€ì§€ë§Œ ë¶€ë“œëŸ½ê²Œ ë˜ë¬¼ì–´.' || E'\n' ||
    '- ì´ì „ ëŒ€í™” íë¦„ì„ ê¸°ì–µí•˜ê³  ê°™ì€ ë§ì„ ë°˜ë³µí•˜ì§€ ë§ˆ.' || E'\n' ||
    'ë¯¸ì…˜ ê·œì¹™: ë¯¸ì…˜ messageëŠ” ì•±ì´ ì—°ì¸ì—ê²Œ ë³´ë‚´ëŠ” ì˜¤ëŠ˜ì˜ ì¶”ì²œ ë¬¸êµ¬ì•¼. ë‚˜ì˜ ì„œìš´í•¨ì´ í’€ë¦¬ë„ë¡ ì—°ì¸ì´ ë‚˜ì—ê²Œ í•´ ì¤„ í–‰ë™ì„ ì œì•ˆí•´.' || E'\n' ||
    '- ì—°ì¸ì—ê²Œ ì§ì ‘ ë§í•˜ëŠ” í˜•ì‹: "ìƒëŒ€ë°©ì—ê²Œ ~í•´ ì£¼ì„¸ìš”", "ì˜¤ëŠ˜ì€ ìƒëŒ€ë°©ê³¼ ~í•´ ë³´ì„¸ìš”". ë‚˜ë¥¼ ê°€ë¦¬í‚¬ ë• ì´ë¦„ì´ ì•„ë‹ˆë¼ ''ìƒëŒ€ë°©''ì´ë¼ê³  ì¨.' || E'\n' ||
    '- ì—°ì¸ì´ ë¶ˆë§Œì„ ë“¤ì—ˆë‹¤ëŠ” ì‚¬ì‹¤ì´ë‚˜ ê³¼ê±°ì˜ ìž˜ëª»(ëŠ¦ìŒ, í°, ë§íˆ¬ ë“±)ì„ ì ˆëŒ€ ì–¸ê¸‰í•˜ì§€ ë§ˆ. ''ëŠ¦ì—ˆìœ¼ë‹ˆ'', ''ì„œìš´'', ''í™”ë‚˜'' ê°™ì€ ë§ ê¸ˆì§€. ê·¸ëƒ¥ ì•±ì´ ì¶”ì²œí•˜ëŠ” ê¸°ë¶„ ì¢‹ì€ ë¯¸ì…˜ì²˜ëŸ¼ ë³´ì—¬ì•¼ í•´.' || E'\n' ||
    '- ì˜ˆ: ëŠ¦ì–´ì„œ ì„œìš´í–ˆë‹¤ë©´ â†’ "ì˜¤ëŠ˜ì€ ì¶œë°œí•  ë•Œ ìƒëŒ€ë°©ì—ê²Œ ''ì§€ê¸ˆ ì¶œë°œ!'' í•œ ì¤„ ë¨¼ì € ë³´ë‚´ ì£¼ì„¸ìš”."' || E'\n' ||
    '- ì˜¤ëŠ˜ ë°”ë¡œ í•  ìˆ˜ ìžˆëŠ” êµ¬ì²´ì ì¸ í–‰ë™ 1ê°œë¥¼ 1~2ë¬¸ìž¥ì˜ í•´ìš”ì²´ë¡œ. ë‘ ë¯¸ì…˜ì€ ì„œë¡œ ë‹¤ë¥¸ í–‰ë™ì´ì–´ì•¼ í•˜ê³  ìµœê·¼ ë³´ë‚¸ ë¯¸ì…˜ê³¼ ê²¹ì¹˜ì§€ ë§ˆ.' || E'\n' ||
    '- titleì€ 15ìž ì´ë‚´.' || E'\n' ||
    'ì¶œë ¥: ë°˜ë“œì‹œ JSON í•˜ë‚˜ë§Œ. {"reply":"ë‚˜ì—ê²Œ í•˜ëŠ” ë‹µ","missions":[{"title":"...","message":"..."}]} ë¯¸ì…˜ì´ í•„ìš” ì—†ìœ¼ë©´ "missions":[].';

  v_out := private.gemini_json(jsonb_build_object(
    'systemInstruction', jsonb_build_object('parts', jsonb_build_array(jsonb_build_object('text', v_sys))),
    'contents', v_contents,
    'generationConfig', jsonb_build_object(
      'temperature', 1.0,
      'topP', 0.95,
      'maxOutputTokens', 800,
      'responseMimeType', 'application/json',
      'thinkingConfig', jsonb_build_object('thinkingLevel', 'minimal')
    )
  ));
  if v_out is null then return null; end if;

  v_reply := btrim(coalesce(v_out->>'reply', ''));
  if length(v_reply) = 0 then return null; end if;

  if jsonb_typeof(v_out->'missions') = 'array' then
    for v_m in select e from jsonb_array_elements(v_out->'missions') as t(e) limit 3 loop
      if jsonb_typeof(v_m) = 'object' and length(btrim(coalesce(v_m->>'message', ''))) > 0 then
        v_missions := v_missions || jsonb_build_array(jsonb_build_object(
          'title', left(coalesce(nullif(btrim(v_m->>'title'), ''), 'ì˜¤ëŠ˜ì˜ ë‹¤ì •í•¨ ë¯¸ì…˜'), 40),
          'message', left(btrim(v_m->>'message'), 300)));
      end if;
    end loop;
  end if;

  return jsonb_build_object('reply', left(v_reply, 600), 'missions', v_missions);
exception when others then
  return null;
end;
$function$;

CREATE OR REPLACE FUNCTION public.generate_mission(feeling text, couple_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'vault', 'extensions'
 SET statement_timeout TO '24s'
AS $function$
#variable_conflict use_column
declare
  v_code text;
  v_count integer;
  v_parsed jsonb;
  v_today date := (timezone('Asia/Seoul', now()))::date;
begin
  if feeling is null or length(btrim(feeling)) = 0 or length(feeling) > 500 then
    return null;
  end if;
  if couple_code is null or length(btrim(couple_code)) = 0 or length(couple_code) > 32 then
    return null;
  end if;
  v_code := btrim(couple_code);
  if auth.uid() is null or not public.is_couple_member(v_code) then
    return null;
  end if;

  -- v11: same per-user ë¹„ë°€ë°© AI cap as sai_chat (older app versions call this from ë¹„ë°€ë°©)
  if not private.take_secret_ai_call() then
    return null;
  end if;

  insert into public.mission_gen_usage as u(couple_code, day, call_count)
  values (v_code, v_today, 1)
  on conflict on constraint mission_gen_usage_pkey
  do update set call_count = u.call_count + 1
  where u.call_count < 30
  returning u.call_count into v_count;
  if v_count is null then
    return null;
  end if;

  v_parsed := private.gemini_json(jsonb_build_object(
    'contents', jsonb_build_array(jsonb_build_object('role', 'user', 'parts', jsonb_build_array(jsonb_build_object('text',
      'ë‹¹ì‹ ì€ ì»¤í”Œ ê´€ê³„ ì½”ì¹­ AI ''ì‚¬ì´ë´‡''ìž…ë‹ˆë‹¤. í•œ ì‚¬ëžŒì´ ì—°ì¸ì—ê²Œ ì„œìš´í•˜ê±°ë‚˜ ì•„ì‰¬ìš´ ë§ˆìŒì„ ë¹„ë°€ë¡œ í„¸ì–´ë†“ì•˜ìŠµë‹ˆë‹¤.' || E'\n' ||
      private.couple_context(v_code) || E'\n' ||
      'í„¸ì–´ë†“ì€ ë§: ' || btrim(feeling) || E'\n' ||
      'ë°˜ë“œì‹œ ë‹¤ìŒ JSONë§Œ ì¶œë ¥í•˜ì„¸ìš”: {"empathy":"...","title":"...","message":"..."}' || E'\n' ||
      '1) empathy: í„¸ì–´ë†“ì€ ì‚¬ëžŒì´ ì“´ ë§ê³¼ ìƒí™©ì„ êµ¬ì²´ì ìœ¼ë¡œ ì§šì–´ ê³µê°í•˜ëŠ” 1~2ë¬¸ìž¥(ë³¸ì¸ë§Œ ë´„). ë»”í•œ í…œí”Œë¦¿ ê¸ˆì§€.' || E'\n' ||
      '2) title: ìƒëŒ€ë°©ì—ê²Œ ë³´ë‚¼ ë°ì¼ë¦¬ ë¯¸ì…˜ ì œëª©(15ìž ì´ë‚´).' || E'\n' ||
      '3) message: ì•±ì´ ì—°ì¸ì—ê²Œ ë³´ë‚´ëŠ” ì˜¤ëŠ˜ì˜ ì¶”ì²œ ë¯¸ì…˜ 1~2ë¬¸ìž¥, í•´ìš”ì²´. "ìƒëŒ€ë°©ì—ê²Œ ~í•´ ì£¼ì„¸ìš”" í˜•ì‹ìœ¼ë¡œ ì—°ì¸ì—ê²Œ ì§ì ‘ ë§í•˜ê³ , í„¸ì–´ë†“ì€ ì‚¬ëžŒì€ ì´ë¦„ ëŒ€ì‹  ''ìƒëŒ€ë°©''ì´ë¼ê³  ë¶€ë¥´ì„¸ìš”. ë¶ˆë§ŒÂ·ì„œìš´í•¨Â·ê³¼ê±°ì˜ ìž˜ëª»ì€ ì ˆëŒ€ ì–¸ê¸‰í•˜ì§€ ë§ê³ , ë§ˆìŒì´ í’€ë¦¬ëŠ” ë°©í–¥ì˜ ì˜¤ëŠ˜ í•  ìˆ˜ ìžˆëŠ” êµ¬ì²´ì ì¸ ë‹¤ì •í•œ í–‰ë™. ìµœê·¼ ë³´ë‚¸ ë¯¸ì…˜ê³¼ ê²¹ì¹˜ì§€ ì•Šê²Œ.'
    )))),
    'generationConfig', jsonb_build_object(
      'temperature', 1.0,
      'maxOutputTokens', 600,
      'responseMimeType', 'application/json',
      'thinkingConfig', jsonb_build_object('thinkingLevel', 'minimal')
    )
  ));

  if v_parsed is null or coalesce(v_parsed->>'empathy', '') = '' or coalesce(v_parsed->>'message', '') = '' then
    return null;
  end if;
  return jsonb_build_object(
    'empathy', left(v_parsed->>'empathy', 500),
    'title', left(coalesce(nullif(v_parsed->>'title', ''), 'ì˜¤ëŠ˜ì˜ ë‹¤ì •í•¨ ë¯¸ì…˜'), 40),
    'message', left(v_parsed->>'message', 500)
  );
exception when others then
  return null;
end;
$function$;

CREATE OR REPLACE FUNCTION public.my_report()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare c public.couples; e private.couple_entitlements; v_me text; v_partner text; v_paid boolean;
  v_total integer; v_way text; v_topics jsonb; v_ready boolean; v_partner_uid uuid; v_secret_n integer;
  v_secret_hit boolean; snap private.report_snapshots;
  -- ë¹„ë°€ë°© keys count only from posts written before today (KST): the gate and the report move at most once a day,
  -- at KST midnight, and a post cannot be tied to a report change the same day.
  v_cut timestamptz := date_trunc('day', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul';
begin
  if auth.uid() is null then return null; end if;
  if (private.paywall_on()).id is null then return jsonb_build_object('enabled', false); end if;
  select * into c from public.couples where user_a = auth.uid() or user_b = auth.uid() limit 1;
  if not found then return null; end if;
  if c.user_a is null or c.user_b is null then
    return jsonb_build_object('enabled', true, 'partner_joined', false);
  end if;
  v_me := case when c.user_a = auth.uid() then 'A' else 'B' end;
  v_partner := case when v_me = 'A' then 'B' else 'A' end;
  v_partner_uid := case when v_me = 'A' then c.user_b else c.user_a end;
  select * into e from private.couple_entitlements where couple_code = c.code;
  v_paid := coalesce(e.paid_until > now(), false);

  -- the partner's ë¹„ë°€ë°© entries written at/after the partner's own [í™•ì¸í–ˆì–´ìš”] for this couple
  select count(*) into v_secret_n from private.secret_topic_tags t
    join private.secret_report_consents s on s.user_id = t.author_user and s.couple_code = t.couple_code
    where t.couple_code = c.code and t.author_user = v_partner_uid and t.created_at >= s.consented_at and t.created_at < v_cut;

  select count(*) into v_total from public.daily_missions d
    where d.couple_code = c.code and ((d.target_role = v_partner and d.accepted) or d.target_role = v_me);

  select w.k into v_way from (values
      ('penguin', 1, 'ì•ˆì•„|ì‚°ì±…|ê±·|ëˆˆë§ž|ëˆˆ ë§ž|í°|í™”ë©´|í‹°íƒ€ìž„|í†¤'),
      ('parrot', 2, 'ë§|í†¡|ëª©ì†Œë¦¬|ì¸ì‚¬|í•œë§ˆë””|ë¬¸ìž¥|ì¹­ì°¬|ì•ˆë¶€|í†µí™”'),
      ('squirrel', 3, 'ì•½ì†|ê¸°ë…ì¼|ê³„íš|ì½”ìŠ¤'),
      ('bear', 4, 'ê°™ì´|í•¨ê»˜|ë°ì´íŠ¸|ì§‘ì—ì„œ|ë…¸ëž˜|ì˜ìƒ'),
      ('rabbit', 5, 'ì„ ë¬¼|ê¹œì§|ìŠ¤í‹°ì»¤|íŽ¸ì§€|ë¹„ë°€|ì´ë²¤íŠ¸')) as w(k, ord, re)
    join public.daily_missions d on d.couple_code = c.code and d.target_role = v_partner and d.accepted
      and (d.title || ' ' || d.message) ~ w.re
    group by w.k, w.ord order by count(*) desc, w.ord limit 1;

  v_ready := v_total >= 3 and v_way is not null;

  if v_ready and v_paid then
    select * into snap from private.report_snapshots where couple_code = c.code and viewer_user = auth.uid();
    if found and snap.made_at > now() - interval '7 days' then
      v_topics := snap.topics;
    else
      select exists (select 1 from private.secret_topic_tags t
          join private.secret_report_consents s on s.user_id = t.author_user and s.couple_code = t.couple_code
          where coalesce(v_secret_n, 0) >= 3 and t.couple_code = c.code and t.author_user = v_partner_uid
            and t.created_at >= s.consented_at and t.created_at < v_cut and t.topic <> 'default'
          group by t.topic having count(*) >= 2)
        into v_secret_hit;

      select coalesce(jsonb_agg(t.k order by t.n desc, t.ord), '[]'::jsonb) into v_topics from (
        select x.k, x.ord, sum(x.n) n from (
          select w.k, w.ord, count(*) n from (values
              ('phone', 1, 'í°|ìŠ¤ë§ˆíŠ¸í°|í•¸ë“œí°|íœ´ëŒ€í°|ìœ íŠœë¸Œ|ì¸ìŠ¤íƒ€|ë¦´ìŠ¤|ê²Œìž„|í™”ë©´|ë§Œ ë³´|ë§Œë´'),
              ('contact', 2, 'ì—°ë½|ë‹µìž¥|ì½ì”¹|ì¹´í†¡|í†¡|ì „í™”|ë°”ë¹ |ë°”ì˜|ë°”ì¨|ë¬´ì†Œì‹|ê¸°ë‹¤ë¦¬'),
              ('affection', 3, 'í‘œí˜„|ì‚¬ëž‘|ì¢‹ì•„|ì˜ˆì˜|ì• ì •|ìŠ¤í‚¨ì‹­|ì•ˆì•„|ê³ ë§ˆ|ê´€ì‹¬|ë¬´ì‹¬|ì™¸ë¡œ'),
              ('date', 4, 'ë°ì´íŠ¸|ì½”ìŠ¤|ê³„íš|ì•½ì†|ì£¼ë§|ì‹ë‹¹|ì¹´íŽ˜|ë§¤ë²ˆ ë‚˜ë§Œ|ë§¨ë‚  ë‚˜ë§Œ'),
              ('tone', 5, 'ë§íˆ¬|ì§œì¦|í™”ë‚´|ì°¨ê°€|ë¬´ëšëš|ë‹¨ë‹µ|í‰ëª…|ìƒì²˜|ì˜ˆë¯¼')) as w(k, ord, re)
            join public.daily_missions d on d.couple_code = c.code and d.target_role = v_me
              and lower(d.title || ' ' || d.message) ~ w.re
            group by w.k, w.ord
          union all
          select t.topic, array_position(array['phone', 'contact', 'affection', 'date', 'tone'], t.topic), count(*)
            from private.secret_topic_tags t
            join private.secret_report_consents s on s.user_id = t.author_user and s.couple_code = t.couple_code
            where coalesce(v_secret_n, 0) >= 3
              and t.couple_code = c.code and t.author_user = v_partner_uid and t.created_at >= s.consented_at and t.created_at < v_cut
              and t.topic <> 'default'
            group by t.topic
            having count(*) >= 2
        ) x group by x.k, x.ord order by sum(x.n) desc, x.ord limit 3) t;

      if coalesce(v_secret_hit, false) then
        insert into private.report_snapshots(couple_code, viewer_user, topics, made_at)
          values (c.code, auth.uid(), v_topics, now())
        on conflict (couple_code, viewer_user) do update set topics = excluded.topics, made_at = excluded.made_at;
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'enabled', true,
    'partner_joined', true,
    'partner_name', case when v_me = 'A' then c.name_b else c.name_a end,
    'ready', v_ready,
    'posts_ready', coalesce(v_secret_n, 0) >= 3,
    'pay_code', e.pay_code,
    'paid', v_paid,
    'way_key', case when v_ready then v_way end,
    'report', case when v_ready and v_paid then jsonb_build_object(
      'topics', v_topics,
      'mission_key', coalesce(v_topics ->> 0, 'default')) end);
end $function$;

CREATE OR REPLACE FUNCTION private.secret_topic(p_text text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'pg_temp'
AS $function$
  select coalesce((
    select w.k from (values
        ('phone', 1, 'í°|ìŠ¤ë§ˆíŠ¸í°|í•¸ë“œí°|íœ´ëŒ€í°|ìœ íŠœë¸Œ|ì¸ìŠ¤íƒ€|ë¦´ìŠ¤|ê²Œìž„|í™”ë©´|ë§Œ ë³´|ë§Œë´'),
        ('contact', 2, 'ì—°ë½|ë‹µìž¥|ì½ì”¹|ì¹´í†¡|í†¡|ì „í™”|ë°”ë¹ |ë°”ì˜|ë°”ì¨|ë¬´ì†Œì‹|ê¸°ë‹¤ë¦¬'),
        ('affection', 3, 'í‘œí˜„|ì‚¬ëž‘|ì¢‹ì•„|ì˜ˆì˜|ì• ì •|ìŠ¤í‚¨ì‹­|ì•ˆì•„|ê³ ë§ˆ|ê´€ì‹¬|ë¬´ì‹¬|ì™¸ë¡œ'),
        ('date', 4, 'ë°ì´íŠ¸|ì½”ìŠ¤|ê³„íš|ì•½ì†|ì£¼ë§|ì‹ë‹¹|ì¹´íŽ˜|ë§¤ë²ˆ ë‚˜ë§Œ|ë§¨ë‚  ë‚˜ë§Œ'),
        ('tone', 5, 'ë§íˆ¬|ì§œì¦|í™”ë‚´|ì°¨ê°€|ë¬´ëšëš|ë‹¨ë‹µ|í‰ëª…|ìƒì²˜|ì˜ˆë¯¼')) as w(k, ord, re)
    where regexp_count(lower(coalesce(p_text, '')), w.re) > 0
    order by regexp_count(lower(coalesce(p_text, '')), w.re) desc, w.ord
    limit 1), 'default');
$function$;
