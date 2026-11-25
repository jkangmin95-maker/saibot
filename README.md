# 우리사이 (사이봇)

서운한 마음을 다정한 데일리 미션으로 번역하는 커플 코칭 PWA. 정적 파일(`public/`)만으로 동작합니다.

- 라이브: https://jkangmin95-maker.github.io/saibot/ (main에 push하면 GitHub Pages Actions가 배포)
- 로그인: 카카오(Supabase Auth). 커플 연결은 `create_couple` / `join_couple` RPC, 테이블은 커플 멤버만 접근(RLS).
- 사이봇 대화: Supabase RPC `sai_chat` → Gemini. Gemini 키는 Supabase Vault(`urisai_gemini_api_key`)에만 있고, 클라이언트에는 anon 키만 있습니다.
- DB 변경은 순서대로: `supabase_schema.sql` → `supabase_migration_v8_kakao.sql` → `supabase_migration_v9_chat.sql` → `supabase_migration_v9_1_review.sql`(되돌리기: `_down.sql`). 테스트: `scripts/test_v8_rls.sql`, `scripts/test_v9_1_review.sql`.
