# 우리사이(Urisai) 5분 만에 핸드폰 앱으로 런칭하기

이 폴더(`urisai-pwa`)는 별도 빌드 과정(`npm build`) 없이 정적 호스팅에 올리기만 하면 바로 아이폰·안드로이드 홈 화면에 앱처럼 설치(PWA)할 수 있도록 구성되어 있습니다.

## 1단계: 무료 HTTPS 주소 만들기 (1분 · Netlify Drop 또는 Vercel)
1. [Netlify Drop](https://app.netlify.com/drop) 또는 [Vercel](https://vercel.com)에 접속합니다.
2. 압축을 푼 `urisai-pwa` 폴더 전체를 화면에 그대로 드래그 앤 드롭합니다.
3. 즉시 `https://xxxx.netlify.app` 형태의 HTTPS 주소가 발급됩니다.

## 2단계: 내 핸드폰 홈 화면에 앱으로 설치하기 (1분)
- **아이폰(iOS Safari)**: 발급된 HTTPS 주소를 Safari로 열기 → 하단 **공유 버튼(↑)** → **홈 화면에 추가** → **추가**.
- **안드로이드(Chrome)**: 발급된 주소를 Chrome으로 열기 → 상단 메뉴(⋮) → **앱 설치** 또는 **홈 화면에 추가**.
- 이제 아이콘을 누르면 브라우저 주소창 없이 일반 모바일 앱처럼 전체 화면으로 실행됩니다.

## 3단계: 연인 핸드폰과 실시간 연결하기 (3분 · Supabase 무료 플랜)
앱은 기본으로 **내 기기 체험 모드(로컬 저장)**로 바로 동작합니다. 두 대의 핸드폰에서 실시간으로 미션을 주고받으려면:
1. [Supabase](https://supabase.com)에서 무료 프로젝트를 생성합니다.
2. 좌측 **SQL Editor**에 `supabase_schema.sql` 내용을 붙여넣고 **Run**을 누릅니다.
3. **Project Settings → API**에서 `Project URL`과 `anon public key`를 복사합니다.
4. 앱 내 우측 상단 **설정(⚙) → 실시간 동기화(Supabase)**에 붙여넣고 저장한 뒤, 같은 **커플 초대 코드(예: S2-4829)**로 두 사람이 각각 내 역할(A / B)을 선택해 입장하면 끝입니다!

## (선택) 실제 AI 번역 고도화
앱 설정(⚙)에서 Gemini API 키를 입력하면 스마트 키워드 매칭 대신 실시간 LLM 감정 번역이 동작합니다. 정식 서비스 운영 시에는 API 키 노출을 막기 위해 Cloudflare Workers 또는 Supabase Edge Functions 프록시를 통해 호출하는 것을 권장합니다.
