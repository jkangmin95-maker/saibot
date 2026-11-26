-- v11.9 prompt encoding repair. Security review before apply. Down: supabase_migration_v11_9_prompt_encoding_down.sql
-- Live public.sai_chat, public.generate_mission, public.my_report, private.secret_topic were stored double-encoded
-- (UTF-8 bytes read as Windows-1252: 0 Hangul characters, e.g. 804 Latin-1 characters in sai_chat). So Gemini gets a garbled
-- system prompt, secret_topic's Korean keywords never match, and fallback titles / report labels come out garbled.
-- This re-creates the four functions with the same code, correctly encoded (sai_chat prompt is character-identical to
-- supabase_migration_v11_paywall.sql). No logic, signature, owner, grant or limit change. Apply with a UTF-8 client (psql: the
-- line below; check afterwards: select proname from pg_proc where prosrc ~ '[À-ÿ]' -> 0 rows).
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

  -- v11: 비밀방 AI cost cap per user per KST day (private.secret_ai_daily_cap). Over it: no Gemini call, no topic key.
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

  -- v11: 속마음 리포트. 기능이 켜져 있고 이 사람이 [확인했어요]를 누른 뒤일 때만, 방금 쓴 문장을
  -- 고정 주제 키 하나로 바꿔 저장한다(문장은 저장하지 않음). 꺼져 있으면 아무것도 하지 않고, 실패해도 대화에 영향 없음.
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
      v_text := private.couple_context(v_code) || E'\n[지금 메시지] ' || v_text;
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
    '너는 커플 관계 코칭 앱 ''우리사이''의 AI 친구 ''사이봇''이야. 지금 대화하는 사람은 ''나''이고, ' ||
    -- v11: 속마음 리포트가 켜져 있을 때만 안내가 바뀐다. 꺼져 있으면 v9.1과 글자 하나까지 같다.
    case when v_report_on
      then '여기 쓴 문장은 연인에게 절대 보이지 않아. 다만 비밀방 안내에서 [확인했어요]를 누른 뒤에 쓴 글은 요즘 마음이 어느 쪽에 있는지만 주제(예: 연락 빈도, 말투 서운함)로 정리돼서 두 사람이 함께 여는 리포트에 들어갈 수 있어. 쓴 문장 그대로나 인용은 절대 들어가지 않아. 이 부분을 물어보면 이대로만 설명해.'
      else '이 비밀방 대화는 연인에게 절대 보이지 않아.' end || E'\n' ||
    '역할:' || E'\n' ||
    '- 상대가 방금 한 말에 직접, 구체적으로 반응해. 상대가 쓴 단어와 상황을 짚어서 말해. 뻔한 위로 문구나 템플릿 같은 말 금지.' || E'\n' ||
    '- 친한 언니/형처럼 따뜻하고 자연스러운 한국어. 반말 금지, 항상 부드러운 해요체(~요). 1~3문장, 짧게. 이모지는 가끔 하나 정도.' || E'\n' ||
    '- 인사·잡담·질문이면 그에 맞게 자연스럽게 대답하고, 필요하면 오늘 연인과 있었던 일을 가볍게 물어봐.' || E'\n' ||
    '- 서운함·아쉬움·바람이 드러나면 공감한 뒤, 연인에게 ''오늘의 미션''으로 슬쩍 보낼 다정한 행동 제안을 2개 만들어.' || E'\n' ||
    '- 정보가 부족하면 미션 없이 한 가지만 부드럽게 되물어.' || E'\n' ||
    '- 이전 대화 흐름을 기억하고 같은 말을 반복하지 마.' || E'\n' ||
    '미션 규칙: 미션 message는 앱이 연인에게 보내는 오늘의 추천 문구야. 나의 서운함이 풀리도록 연인이 나에게 해 줄 행동을 제안해.' || E'\n' ||
    '- 연인에게 직접 말하는 형식: "상대방에게 ~해 주세요", "오늘은 상대방과 ~해 보세요". 나를 가리킬 땐 이름이 아니라 ''상대방''이라고 써.' || E'\n' ||
    '- 연인이 불만을 들었다는 사실이나 과거의 잘못(늦음, 폰, 말투 등)을 절대 언급하지 마. ''늦었으니'', ''서운'', ''화나'' 같은 말 금지. 그냥 앱이 추천하는 기분 좋은 미션처럼 보여야 해.' || E'\n' ||
    '- 예: 늦어서 서운했다면 → "오늘은 출발할 때 상대방에게 ''지금 출발!'' 한 줄 먼저 보내 주세요."' || E'\n' ||
    '- 오늘 바로 할 수 있는 구체적인 행동 1개를 1~2문장의 해요체로. 두 미션은 서로 다른 행동이어야 하고 최근 보낸 미션과 겹치지 마.' || E'\n' ||
    '- title은 15자 이내.' || E'\n' ||
    '출력: 반드시 JSON 하나만. {"reply":"나에게 하는 답","missions":[{"title":"...","message":"..."}]} 미션이 필요 없으면 "missions":[].';

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
          'title', left(coalesce(nullif(btrim(v_m->>'title'), ''), '오늘의 다정함 미션'), 40),
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

  -- v11: same per-user 비밀방 AI cap as sai_chat (older app versions call this from 비밀방)
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
      '당신은 커플 관계 코칭 AI ''사이봇''입니다. 한 사람이 연인에게 서운하거나 아쉬운 마음을 비밀로 털어놓았습니다.' || E'\n' ||
      private.couple_context(v_code) || E'\n' ||
      '털어놓은 말: ' || btrim(feeling) || E'\n' ||
      '반드시 다음 JSON만 출력하세요: {"empathy":"...","title":"...","message":"..."}' || E'\n' ||
      '1) empathy: 털어놓은 사람이 쓴 말과 상황을 구체적으로 짚어 공감하는 1~2문장(본인만 봄). 뻔한 템플릿 금지.' || E'\n' ||
      '2) title: 상대방에게 보낼 데일리 미션 제목(15자 이내).' || E'\n' ||
      '3) message: 앱이 연인에게 보내는 오늘의 추천 미션 1~2문장, 해요체. "상대방에게 ~해 주세요" 형식으로 연인에게 직접 말하고, 털어놓은 사람은 이름 대신 ''상대방''이라고 부르세요. 불만·서운함·과거의 잘못은 절대 언급하지 말고, 마음이 풀리는 방향의 오늘 할 수 있는 구체적인 다정한 행동. 최근 보낸 미션과 겹치지 않게.'
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
    'title', left(coalesce(nullif(v_parsed->>'title', ''), '오늘의 다정함 미션'), 40),
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
  -- 비밀방 keys count only from posts written before today (KST): the gate and the report move at most once a day,
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

  -- the partner's 비밀방 entries written at/after the partner's own [확인했어요] for this couple
  select count(*) into v_secret_n from private.secret_topic_tags t
    join private.secret_report_consents s on s.user_id = t.author_user and s.couple_code = t.couple_code
    where t.couple_code = c.code and t.author_user = v_partner_uid and t.created_at >= s.consented_at and t.created_at < v_cut;

  select count(*) into v_total from public.daily_missions d
    where d.couple_code = c.code and ((d.target_role = v_partner and d.accepted) or d.target_role = v_me);

  select w.k into v_way from (values
      ('penguin', 1, '안아|산책|걷|눈맞|눈 맞|폰|화면|티타임|톤'),
      ('parrot', 2, '말|톡|목소리|인사|한마디|문장|칭찬|안부|통화'),
      ('squirrel', 3, '약속|기념일|계획|코스'),
      ('bear', 4, '같이|함께|데이트|집에서|노래|영상'),
      ('rabbit', 5, '선물|깜짝|스티커|편지|비밀|이벤트')) as w(k, ord, re)
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
              ('phone', 1, '폰|스마트폰|핸드폰|휴대폰|유튜브|인스타|릴스|게임|화면|만 보|만봐'),
              ('contact', 2, '연락|답장|읽씹|카톡|톡|전화|바빠|바쁘|바쁨|무소식|기다리'),
              ('affection', 3, '표현|사랑|좋아|예쁘|애정|스킨십|안아|고마|관심|무심|외로'),
              ('date', 4, '데이트|코스|계획|약속|주말|식당|카페|매번 나만|맨날 나만'),
              ('tone', 5, '말투|짜증|화내|차가|무뚝뚝|단답|퉁명|상처|예민')) as w(k, ord, re)
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
        ('phone', 1, '폰|스마트폰|핸드폰|휴대폰|유튜브|인스타|릴스|게임|화면|만 보|만봐'),
        ('contact', 2, '연락|답장|읽씹|카톡|톡|전화|바빠|바쁘|바쁨|무소식|기다리'),
        ('affection', 3, '표현|사랑|좋아|예쁘|애정|스킨십|안아|고마|관심|무심|외로'),
        ('date', 4, '데이트|코스|계획|약속|주말|식당|카페|매번 나만|맨날 나만'),
        ('tone', 5, '말투|짜증|화내|차가|무뚝뚝|단답|퉁명|상처|예민')) as w(k, ord, re)
    where regexp_count(lower(coalesce(p_text, '')), w.re) > 0
    order by regexp_count(lower(coalesce(p_text, '')), w.re) desc, w.ord
    limit 1), 'default');
$function$;
