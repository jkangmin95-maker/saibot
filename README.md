# 우리사이 (사이봇)

서운한 마음을 다정한 데일리 미션으로 번역하는 커플 코칭 PWA입니다. 별도 번들 없이 정적 파일로 동작합니다.

- 라이브: https://jkangmin95-maker.github.io/saibot/
- 기본은 기기 로컬 저장(체험 모드)으로 바로 사용할 수 있습니다.
- 두 대의 핸드폰 실시간 동기화는 앱 설정에서 Supabase Project URL과 anon public key를 입력한 뒤, 같은 커플 초대 코드로 입장하면 됩니다. 스키마는 `supabase_schema.sql`을 참고하세요.
- Gemini API 키는 선택 사항입니다. 입력하면 스마트 키워드 매칭 대신 LLM 번역을 사용합니다.

GitHub Pages 배포는 `.github/workflows/deploy.yml`에서 `npm ci && npm run build` 후 `dist/`를 올립니다.
