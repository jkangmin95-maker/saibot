# 우리사이 (사이봇)

서운한 마음을 다정한 데일리 미션으로 번역하는 커플 코칭 PWA. 정적 파일(`public/`)만으로 동작합니다.

- 라이브: https://jkangmin95-maker.github.io/saibot/ (main에 push하면 GitHub Pages Actions가 배포)
- 로그인: 카카오(Supabase Auth). 커플 연결은 `create_couple` / `join_couple` RPC, 테이블은 커플 멤버만 접근(RLS).
- 사이봇 대화: Supabase RPC `sai_chat` → Gemini. Gemini 키는 Supabase Vault(`urisai_gemini_api_key`)에만 있고, 클라이언트에는 anon 키만 있습니다.
- DB 변경은 순서대로: `supabase_schema.sql` → `supabase_migration_v8_kakao.sql` → `supabase_migration_v9_chat.sql` → `supabase_migration_v9_1_review.sql`(되돌리기: `_down.sql`) → `supabase_migration_v10_share_quiz.sql`(되돌리기: `supabase_migration_v10_share_quiz_down.sql`). 테스트: `scripts/test_v8_rls.sql`, `scripts/test_v9_1_review.sql`, `scripts/test_v10.sql` (로컬 Postgres에서 한 번에: `scripts/run_local_sql_tests.sh`).
- v10: 우리 온도 탭에 **우리 조합 카드**(둘 다 동의해야 공유, `share_consents`)와 **서로 맞히기 테스트**(`quiz.html`, 로그인 없음, anon RPC만) 진입 카드. 퍼널 숫자는 `private.funnel_events` (조회 SQL은 v10 마이그레이션 맨 아래).
- `quiz.html`은 CDN 스크립트 없이 미리 빌드한 `quiz.css`(Tailwind 3.4.17)를 씁니다. 클래스를 바꾸면 `scripts/build_quiz_css.sh`로 다시 빌드하세요.
