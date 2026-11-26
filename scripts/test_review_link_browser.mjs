// Headless 390px check of the no-login review link against a stubbed Supabase (fake accounts only). Serve public/ on 127.0.0.1:8797, then: node scripts/test_review_link_browser.mjs (needs playwright-core + Chrome).
import { chromium } from 'playwright-core';
import fs from 'fs';
const OUT = process.env.OUT_DIR || "/tmp";
const BASE = 'http://127.0.0.1:8797/index.html';
const A = { email: 'review-a-test@urisai-review.example.com', pw: 'PwA' + 'x'.repeat(37), id: '11111111-1111-4111-8111-111111111111' };
const B = { email: 'review-b-test@urisai-review.example.com', pw: 'PwB' + 'y'.repeat(37), id: '22222222-2222-4222-8222-222222222222' };
const C = { email: 'evil-c@example.com', pw: 'PwC' + 'z'.repeat(37), id: '33333333-3333-4333-8333-333333333333' };
const D = { email: 'evil-d@example.com', pw: 'PwD' + 'w'.repeat(37), id: '44444444-4444-4444-8444-444444444444' };
const REAL = { email: '', id: '55555555-5555-4555-8555-555555555555' };
const kEvil = Buffer.from(JSON.stringify({ v: 1, a: [C.email, C.pw], b: [D.email, D.pw] })).toString('base64url');
const k = Buffer.from(JSON.stringify({ v: 1, a: [A.email, A.pw], b: [B.email, B.pw] })).toString('base64url');
const results = []; const ok = (n, c) => { results.push((c ? 'PASS ' : 'FAIL ') + n); };
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const jwt = (u) => b64({ alg: 'HS256', typ: 'JWT' }) + '.' + b64({ sub: u.id, role: 'authenticated', aud: 'authenticated', email: u.email, exp: Math.floor(Date.now() / 1000) + 3600 }) + '.sig';
const browser = await chromium.launch({ executablePath: '/usr/bin/google-chrome', args: ['--no-sandbox'] });

async function run(name, url, fn, preSession) {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, serviceWorkers: 'block' });
  if (preSession) {
    const sess = { access_token: jwt(preSession), token_type: 'bearer', expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600, refresh_token: 'r-real',
      user: { id: preSession.id, aud: 'authenticated', role: 'authenticated', email: preSession.email, app_metadata: { provider: 'kakao' }, user_metadata: { nickname: '실사용자' } } };
    await ctx.addInitScript((v) => { if (!sessionStorage.getItem('__pre')) { sessionStorage.setItem('__pre', '1'); localStorage.setItem('sb-iyligsrpaxitlpuwbdjx-auth-token', v); } }, JSON.stringify(sess));
  }
  const page = await ctx.newPage();
  const log = { token: [], urls: [], referers: [], logout: 0, errors: [] };
  page.on('pageerror', (e) => log.errors.push(String(e)));
  page.on('request', (r) => { log.urls.push(r.url()); const ref = r.headers()['referer']; if (ref) log.referers.push(ref); });
  await page.route('https://iyligsrpaxitlpuwbdjx.supabase.co/**', async (route) => {
    const req = route.request(); const u = new URL(req.url());
    const auth = req.headers()['authorization'] || '';
    let sub = ''; try { sub = JSON.parse(Buffer.from(auth.split(' ')[1].split('.')[1], 'base64url')).sub; } catch {}
    if (u.pathname === '/auth/v1/token') {
      const body = JSON.parse(req.postData() || '{}'); log.token.push(body);
      const usr = [A, B, C, D].find((x) => body.email === x.email && body.password === x.pw) || null;
      if (!usr) return route.fulfill({ status: 400, contentType: 'application/json', body: '{"error":"invalid_grant"}' });
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ access_token: jwt(usr), token_type: 'bearer', expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600, refresh_token: 'r-' + usr.id,
        user: { id: usr.id, aud: 'authenticated', role: 'authenticated', email: usr.email, app_metadata: { provider: 'email' }, user_metadata: {} } }) });
    }
    if (u.pathname === '/auth/v1/logout') { log.logout++; return route.fulfill({ status: 204, body: '' }); }
    if (u.pathname === '/rest/v1/rpc/my_couple') {
      const role = sub === B.id || sub === D.id ? 'B' : 'A';
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ code: 'S2-TEST01', role, name_a: '검수 나', name_b: '검수 연인', partner_joined: true, warmth_temp: 37.5, completed_count: 0 }) });
    }
    if (u.pathname === '/rest/v1/rpc/am_reviewer') return route.fulfill({ status: 200, contentType: 'application/json', body: String(sub === A.id || sub === B.id) });
    if (req.method() === 'GET') return route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
    return route.fulfill({ status: 404, contentType: 'application/json', body: '{"message":"stub"}' });
  });
  await page.goto(url);
  await fn(page, log);
  const secretHits = log.urls.filter((x) => x.includes(k) || x.includes(kEvil) || x.includes(C.pw) || x.includes(A.pw) || x.includes(B.pw) || x.includes('k=ey'));
  ok(name + ': no request URL carries the key or a password', secretHits.length === 0);
  ok(name + ': no Referer carries a fragment', log.referers.every((r) => !r.includes('#')));
  ok(name + ': no page errors', log.errors.length === 0 || (console.log(log.errors), false));
  await ctx.close();
}

const settingsOpen = (p) => p.locator('[data-review-tools]').waitFor({ timeout: 15000 });
await run('link', BASE + '?review=1#k=' + k, async (p, log) => {
  await settingsOpen(p);
  ok('link: signInWithPassword as A with the right password', log.token.length === 1 && log.token[0].email === A.email && log.token[0].password === A.pw);
  ok('link: fragment and ?review removed from the address', !p.url().includes('#') && !p.url().includes('review') && !p.url().includes('k='));
  ok('link: Settings opened with the 4 review buttons', (await p.locator('[data-review-tools] button').count()) === 4);
  ok('link: 상대로 보기 shown', await p.locator('[data-action=review-switch]', { hasText: '상대로 보기' }).isVisible());
  ok('link: key kept on this device only', (await p.evaluate(() => localStorage.getItem('urisai_review_k'))) === k);
  await p.waitForTimeout(800);
  await p.screenshot({ path: OUT + '/1-settings-as-A.png' });
  await p.click('[data-action=review-switch]');
  await p.waitForFunction(() => document.body.innerText.includes('연인 화면이에요'), null, { timeout: 15000 });
  ok('switch: signed in as B', log.token.length === 2 && log.token[1].email === B.email);
  ok('switch: local sign-out of A first', log.logout === 1);
  await p.waitForTimeout(600);
  await p.screenshot({ path: OUT + '/2-after-switch-B.png' });
  await p.click('[data-action=open-settings]');
  await settingsOpen(p);
  ok('switch: 나로 보기 shown as B', await p.locator('[data-action=review-switch]', { hasText: '나로 보기' }).isVisible());
  await p.waitForTimeout(500);
  await p.screenshot({ path: OUT + '/3-settings-as-B.png' });
  await p.click('[data-action=review-switch]');
  await p.waitForFunction(() => document.body.innerText.includes('내 화면이에요'), null, { timeout: 15000 });
  ok('switch back: signed in as A again', log.token.length === 3 && log.token[2].email === A.email);
  await p.click('[data-action=open-settings]'); await settingsOpen(p);
  await p.click('[data-action=logout-ask]'); await p.click('[data-action=logout-confirm]');
  await p.waitForTimeout(800);
  ok('logout: key removed from this device', (await p.evaluate(() => localStorage.getItem('urisai_review_k'))) === null);
  ok('logout: Kakao login screen back', await p.locator('[data-action=kakao-login]').first().isVisible());
});
await run('plain', BASE, async (p, log) => {
  await p.waitForTimeout(2500);
  ok('plain: no password sign-in without the link', log.token.length === 0);
  ok('plain: Kakao login button shown', await p.locator('[data-action=kakao-login]').first().isVisible());
  await p.screenshot({ path: OUT + '/4-plain-kakao.png' });
});
await run('badkey', BASE + '?review=1#k=garbage', async (p, log) => {
  await p.waitForTimeout(2500);
  ok('bad key: ignored, no sign-in, fragment removed', log.token.length === 0 && !p.url().includes('k='));
});
await run('real-session', BASE + '?review=1#k=' + k, async (p, log) => {
  await p.waitForTimeout(3000);
  ok('real non-reviewer + valid link: no password sign-in, no sign-out', log.token.length === 0 && log.logout === 0);
  ok('real non-reviewer + valid link: key deleted, fragment removed', (await p.evaluate(() => localStorage.getItem('urisai_review_k'))) === null && !p.url().includes('k='));
  ok('real non-reviewer + valid link: still in own session', (await p.evaluate(() => !!localStorage.getItem('sb-iyligsrpaxitlpuwbdjx-auth-token'))) && (await p.locator('[data-action=open-settings]').count()) > 0);
  await p.screenshot({ path: OUT + '/5-real-user-link-ignored.png' });
}, REAL);
await run('evil-link', BASE + '?review=1#k=' + kEvil, async (p, log) => {
  await p.waitForTimeout(3500);
  ok('non-allowlisted link: password sign-in tried once, then signed out', log.token.length === 1 && log.token[0].email === C.email && log.logout === 1);
  ok('non-allowlisted link: key cleared, no session left', (await p.evaluate(() => localStorage.getItem('urisai_review_k') === null && !localStorage.getItem('sb-iyligsrpaxitlpuwbdjx-auth-token'))));
  ok('non-allowlisted link: ends on Kakao login screen', await p.locator('[data-action=kakao-login]').first().waitFor({ state: 'visible', timeout: 10000 }).then(() => true).catch(() => false));
  await p.screenshot({ path: OUT + '/6-evil-link-signed-out.png' });
});
await run('invite', BASE + '#invite=S2-ABC123', async (p, log) => {
  await p.waitForTimeout(1500);
  ok('invite fragment still handled (removed from address)', !p.url().includes('invite'));
});
await browser.close();
console.log(results.join('\n'));
const f = results.filter((r) => r.startsWith('FAIL')).length;
console.log(`TOTAL PASS = ${results.length - f}  FAIL = ${f}`);
fs.writeFileSync(OUT + '/results.txt', results.join('\n') + `\nTOTAL PASS = ${results.length - f}  FAIL = ${f}\n`);
process.exit(f ? 1 : 0);
