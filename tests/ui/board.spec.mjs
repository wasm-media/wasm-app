// اختبار اللوحة (1ب) — Chromium آلي. يفشل برمز خروج 1 عند أول بند لا يتحقق، ويحفظ لقطة لكل عرض في reviews/.
// البنود: 3.1 (RTL، الأعمدة السبعة من اليمين، لا تمرير أفقي للصفحة، فتح/نقل/إرجاع/إلغاء/سجل من الواجهة)
//         3.2 (لا أرقام هندية، التاريخ 25/09/2026) · 3.3 (الموظف لا يرى اللوحة ولا أي شغلة)
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
const require = createRequire(import.meta.url);
const { chromium } = require(execSync('npm root -g').toString().trim() + '/playwright');

const BASE = process.env.BASE || 'http://127.0.0.1:8080';
// REAL=1: الواجهة تتكلم مع Supabase حقيقي (Auth وPostgREST الحقيقيان من `supabase start`)؛ تُتخطّى فحوص المحاكي التي تحتاج مفاتيح اختبار
const REAL = process.env.REAL === '1';
const AUTH = REAL ? process.env.AUTH_URL : '';        // فارغ = الخادم نفسه (المحاكي)
const APIKEY = process.env.ANON_KEY || '';
const [W, H] = (process.env.VIEWPORT || '1440x900').split('x').map(Number);
const SHOTS = process.env.SHOTS;
const tag = `${W}x${H}/${process.env.LANG_UI || 'ar'}`;
const STAGES = ['intake', 'quote', 'client_approval', 'design', 'review', 'execution', 'delivered'];
const LABELS = ['استقبال', 'عرض سعر', 'موافقة العميل', 'تصميم', 'مراجعة', 'تنفيذ', 'تسليم'];
let passed = 0;
function ok(cond, what) {
  if (!cond) { console.log(`FAIL [${tag}] ${what}`); process.exit(1); }
  passed++; console.log(`ok   [${tag}] ${what}`);
}
const noIndic = async (page, where) => ok(!/[٠-٩۰-۹]/.test(await page.evaluate(() => document.body.innerText + ' ' + [...document.querySelectorAll('input,textarea,select')].map((e) => e.value).join(' '))), `3.2 no Arabic-Indic digits incl. field values (${where})`);
const noHScroll = async (page, where) => ok(await page.evaluate(() => {
  if (getComputedStyle(document.documentElement).overflowX === 'hidden' || getComputedStyle(document.body).overflowX === 'hidden') return false; // لا إخفاء يغطّي الفيض
  return document.documentElement.scrollWidth <= window.innerWidth + 1;
}), `3.1 no page horizontal scroll (${where})`);
async function lastColumnReachable(page) {
  return page.evaluate(async () => {
    const sc = document.querySelector('.board-scroller'); const last = document.querySelector('[data-stage=delivered]');
    if (!sc || !last) return false;
    sc.scrollLeft = -sc.scrollWidth; // RTL: النهاية يسارًا
    await new Promise((r) => setTimeout(r, 300));
    const b = last.getBoundingClientRect();
    return b.left >= -1 && b.right <= window.innerWidth + 1 && document.documentElement.scrollWidth <= window.innerWidth + 1;
  });
}
async function login(page, email) {
  await page.goto(BASE + '/');
  await page.fill('[data-testid=login-email]', email);
  await page.fill('[data-testid=login-password]', 'test-pass');
  await page.click('[data-testid=login-submit]');
}
async function colOf(page, num) {
  return page.evaluate((n) => {
    const card = document.querySelector(`[data-testid=card-${n}]`);
    const col = card && card.closest('[data-stage]');
    return col ? col.getAttribute('data-stage') : (card && card.closest('[data-testid=cancelled-list]') ? 'cancelled' : null);
  }, num);
}
async function waitCol(page, num, stage) {
  await page.waitForFunction(([n, s]) => {
    const card = document.querySelector(`[data-testid=card-${n}]`);
    if (!card) return false;
    const col = card.closest('[data-stage]');
    return s === 'cancelled' ? !!card.closest('[data-testid=cancelled-list]') : (col && col.getAttribute('data-stage') === s);
  }, [num, stage], { timeout: 8000 }).catch(() => {});
  return colOf(page, num);
}

const LANG_UI = process.env.LANG_UI || 'ar';
const browser = await chromium.launch({ args: [`--lang=${LANG_UI}`] });
try {
  // ===== الشريك =====
  const ctx = await browser.newContext({ viewport: { width: W, height: H }, locale: 'ar' });
  const page = await ctx.newPage();
  await page.goto(BASE + '/');
  ok(await page.evaluate(() => document.documentElement.getAttribute('dir')) === 'rtl', '3.1 html dir=rtl');
  ok(await page.evaluate(() => document.documentElement.getAttribute('lang')) === 'ar', 'html lang=ar');
  await login(page, 'partner1@wasm.test');
  await page.waitForSelector('[data-testid=board]', { timeout: 8000 }).catch(() => {});
  ok(await page.isVisible('[data-testid=board]'), 'partner sees board');

  const cols = await page.$$eval('[data-testid=board] [data-stage]', (els) => els.map((e) => ({
    stage: e.getAttribute('data-stage'), head: e.querySelector('[data-testid=col-title]')?.textContent.trim(), x: e.getBoundingClientRect().left })));
  ok(cols.length === 7, `3.1 seven columns (got ${cols.length})`);
  ok(JSON.stringify(cols.map((c) => c.stage)) === JSON.stringify(STAGES), '3.1 column order intake→delivered');
  ok(cols.every((c, i) => c.head === LABELS[i]), '3.1 Arabic column titles');
  ok(cols.every((c, i) => i === 0 || c.x < cols[i - 1].x), '3.1 columns flow right-to-left («استقبال» rightmost)');
  await noHScroll(page, 'empty board');
  ok(await lastColumnReachable(page), '3.1 last column «تسليم» reachable by scrolling the columns row');
  await page.evaluate(() => { document.querySelector('.board-scroller').scrollLeft = 0; });

  // فتح شغلة من الواجهة
  await page.click('[data-testid=new-job]');
  await page.fill('[data-testid=nj-client]', 'مطعم الزيتونة');
  await page.fill('[data-testid=nj-title]', 'منيو مطبوع');
  await page.selectOption('[data-testid=nj-type]', 'print');
  await page.fill('[data-testid=nj-due]', '31/02/2026');
  await page.click('[data-testid=nj-submit]');
  ok(await page.isVisible('[data-testid=nj-msg]') && !(await page.$('[data-testid=card-9001]')), '3.2 impossible date 31/02/2026 rejected before sending');
  await page.fill('[data-testid=nj-due]', '05/10/2026');
  ok(await page.inputValue('[data-testid=nj-due]') === '05/10/2026', '3.2 due-date field displays exactly 05/10/2026 (browser language independent)');
  await noIndic(page, 'new-job form');
  await page.fill('[data-testid=nj-notes]', 'سعر مبدئي 900');
  await page.click('[data-testid=nj-submit]');
  ok(await waitCol(page, 9001, 'intake') === 'intake', '3.1 partner opens job → #9001 in «استقبال»');
  const cardText = await page.textContent('[data-testid=card-9001]');
  ok(cardText.includes('9001') && cardText.includes('مطعم الزيتونة') && cardText.includes('منيو مطبوع'), 'card shows number, client, title');
  ok(cardText.includes('05/10/2026'), '3.2 due date shown as 05/10/2026');

  // نقل وإرجاع
  await page.click('[data-testid=card-next-9001]');
  ok(await waitCol(page, 9001, 'quote') === 'quote', '3.1 next → «عرض سعر»');
  await page.click('[data-testid=card-back-9001]');
  ok(await waitCol(page, 9001, 'intake') === 'intake', '3.1 back → «استقبال»');
  ok(!(await page.isVisible('[data-testid=card-back-9001]')), 'no back button in «استقبال»');
  await page.click('[data-testid=card-next-9001]');
  await waitCol(page, 9001, 'quote');
  await page.click('[data-testid=card-next-9001]');
  ok(await waitCol(page, 9001, 'client_approval') === 'client_approval', '3.1 next → «موافقة العميل»');
  await noHScroll(page, 'board with a job');
  await noIndic(page, 'board');
  if (SHOTS) await page.screenshot({ path: `${SHOTS}/slice1b-${tag.replace("/", "-")}-board.png`, fullPage: true });

  // الإلغاء بسبب — السبب الفارغ يُرفض في الواجهة قبل السيرفر
  await page.click('[data-testid=card-cancel-9001]');
  await page.fill('[data-testid=cancel-reason]', '   ');
  await page.click('[data-testid=cancel-confirm]');
  ok(await colOf(page, 9001) === 'client_approval', 'blank reason does not cancel');
  await page.fill('[data-testid=cancel-reason]', 'العميل أجّل');
  await page.click('[data-testid=cancel-confirm]');
  ok(await waitCol(page, 9001, 'cancelled') === 'cancelled', '3.1 cancel → leaves board, appears in «ملغاة»');

  // السجل
  await page.click('[data-testid=card-log-9001]');
  await page.waitForSelector('[data-testid=log-panel] [data-testid=log-row]', { timeout: 8000 }).catch(() => {});
  const rows = await page.$$eval('[data-testid=log-panel] [data-testid=log-row]', (els) => els.map((e) => e.innerText));
  ok(rows.length === 5, `3.1 log has 5 lines (got ${rows.length})`);
  ok(rows.every((r) => r.includes('الشريك الأول')), 'log shows mover name');
  const today = new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Hebron', day: '2-digit', month: '2-digit', year: 'numeric' }).format(new Date());
  ok(rows.every((r) => r.includes(today)), `3.2 log dates are today in Gaza as dd/mm/yyyy (${today})`);
  const expectMoves = ['استقبال ← عرض سعر', 'عرض سعر ← استقبال', 'استقبال ← عرض سعر', 'عرض سعر ← موافقة العميل', 'موافقة العميل ← ملغاة'];
  ok(rows.every((r, i) => r.split('\n')[0].trim() === expectMoves[i]), '3.1 log lines in order, each «من ← إلى» exact');
  ok((await page.textContent('[data-testid=log-panel]')).includes('سعر مبدئي 900'), 'partner sees the job notes in the job panel');
  ok(rows.some((r) => r.includes('العميل أجّل')), 'log shows cancel reason');
  await noIndic(page, 'log panel');
  await noHScroll(page, 'log panel');
  if (SHOTS) await page.screenshot({ path: `${SHOTS}/slice1b-${tag.replace("/", "-")}-log.png`, fullPage: true });
  await page.click('[data-testid=log-close]');

  // طلب متأخر: شريك ثانٍ ينقل الشغلة، والأول يضغط من شاشة قديمة ← رسالة واضحة واللوحة تتحدّث
  await page.click('[data-testid=new-job]');
  await page.fill('[data-testid=nj-client]', 'مدرسة النور');
  await page.fill('[data-testid=nj-title]', 'رول أب');
  await page.selectOption('[data-testid=nj-type]', 'design');
  await page.click('[data-testid=nj-submit]');
  await waitCol(page, 9002, 'intake');
  const ctx2 = await browser.newContext({ viewport: { width: W, height: H }, locale: 'ar' });
  const p2 = await ctx2.newPage();
  await login(p2, 'partner2@wasm.test');
  await p2.waitForSelector('[data-testid=card-9002]', { timeout: 8000 });
  await p2.click('[data-testid=card-next-9002]');
  await waitCol(p2, 9002, 'quote');
  await page.click('[data-testid=card-next-9002]');
  await page.waitForSelector('[data-testid=error]', { timeout: 8000 }).catch(() => {});
  ok(await page.isVisible('[data-testid=error]'), 'stale click shows an error message');
  ok(await waitCol(page, 9002, 'quote') === 'quote', 'board refreshes to the real stage after stale click');
  await ctx2.close();

  // ===== الخروج الآمن (I13) =====
  if (!REAL) {
  // (أ) الخادم يفشل في الخروج ← رسالة ظاهرة، ولا يُعرض خروج ناجح، والجلسة باقية لإعادة المحاولة
  await page.evaluate(() => fetch('/__test/fail-logout?on=1'));
  await page.click('#logout');
  await page.waitForSelector('[data-testid=error]:not([hidden])', { timeout: 8000 }).catch(() => {});
  ok(await page.isVisible('[data-testid=error]') && await page.isVisible('[data-testid=board]'), 'I13 server logout failure is shown, not a fake success');
  ok(await page.evaluate(() => localStorage.getItem('wasm.session')) !== null, 'I13 session kept after failed logout (can retry)');
  await page.evaluate(() => fetch('/__test/fail-logout?on=0'));
  // (ب) رمز الدخول انتهى في الخادم (تبويب مفتوح أطول من عمر الرمز): الخروج يجدّد أولًا ثم يُبطل، ولا يبقى رمز تجديد حي
  await page.evaluate(async () => {
    await fetch('/__test/ttl?s=2');
    const x = JSON.parse(localStorage.getItem('wasm.session')); x.expires_at = 0; localStorage.setItem('wasm.session', JSON.stringify(x));
  });
  await page.reload();                                   // عند التحميل تتجدّد الجلسة برمز عمره ثانيتان في الخادم
  await page.waitForSelector('[data-testid=board]', { timeout: 8000 });
  await page.waitForTimeout(3500);                       // الرمز الذي بيد الصفحة انتهى الآن في الخادم
  }
  const saved = await page.evaluate(() => JSON.parse(localStorage.getItem('wasm.session')));
  const logoutReqs = [];
  page.on('request', (r) => { if (r.url().includes('/auth/v1/logout')) logoutReqs.push(r.method()); });
  await page.click('#logout');
  await page.waitForSelector('[data-testid=login-email]', { timeout: 8000 });
  ok(logoutReqs.includes('POST'), 'logout calls POST /auth/v1/logout');
  const reuse = await page.evaluate(async ([rt, auth, key]) => (await fetch(`${auth}/auth/v1/token?grant_type=refresh_token`, { method: 'POST', headers: { 'content-type': 'application/json', apikey: key }, body: JSON.stringify({ refresh_token: rt }) })).status, [saved.refresh_token, AUTH, APIKEY]);
  ok(reuse === 400, `refresh token copied before logout is dead after it (status ${reuse})`);
  if (!REAL) {
    const live = await page.evaluate(async () => Number(await (await fetch('/__test/live-refresh?email=partner1@wasm.test')).text()));
    ok(live === 0, `I13 no live refresh token left for the partner after logout with an expired access token (live=${live})`);
    await page.evaluate(() => fetch('/__test/ttl?s=3600'));
  } else {
    // P17: التسجيل الذاتي مغلق في Supabase Auth الحقيقي — بسببه هو (signup_disabled)، لا بأي 4xx آخر
    // (مزوّد بريد مطفأ أو كلمة سر ضعيفة يرجعان 422 أيضًا، فيمرّ الفحص كاذبًا — N7)
    const su = await page.evaluate(async ([auth, key]) => { const r = await fetch(`${auth}/auth/v1/signup`, { method: 'POST', headers: { 'content-type': 'application/json', apikey: key }, body: JSON.stringify({ email: 'intruder@wasm.test', password: 'Intruder-pass-123' }) }); let j = {}; try { j = await r.json(); } catch { /* ليس JSON */ } return { status: r.status, code: j.error_code || '' }; }, [AUTH, APIKEY]);
    ok(su.status === 422 && su.code === 'signup_disabled', `P17 self-signup rejected by real Supabase Auth (status ${su.status}, ${su.code || 'no error_code'})`);
  }
  ok(await page.evaluate(() => localStorage.getItem('wasm.session')) === null, 'logout clears the stored session');
  await ctx.close();

  // ===== الموظف =====
  const ec = await browser.newContext({ viewport: { width: W, height: H }, locale: 'ar' });
  const ep = await ec.newPage();
  await login(ep, 'employee@wasm.test');
  await ep.waitForSelector('[data-testid=no-access]', { timeout: 8000 }).catch(() => {});
  ok(await ep.isVisible('[data-testid=no-access]'), '3.3 employee sees no-access message');
  ok((await ep.$$('[data-testid=board]')).length === 0, '3.3 employee: no board');
  ok((await ep.$$('[data-testid^=card-]')).length === 0, '3.3 employee: no job cards');
  const et = await ep.evaluate(() => document.body.innerText);
  ok(!et.includes('مطعم الزيتونة') && !et.includes('9001'), '3.3 employee: no job data in page');
  await noIndic(ep, 'employee');
  if (SHOTS) await ep.screenshot({ path: `${SHOTS}/slice1b-${tag.replace("/", "-")}-employee.png`, fullPage: true });
  await ec.close();

  // ===== كلمة سر خاطئة =====
  const bc = await browser.newContext({ viewport: { width: W, height: H }, locale: 'ar' });
  const bp = await bc.newPage();
  await bp.goto(BASE + '/');
  await bp.fill('[data-testid=login-email]', 'partner1@wasm.test');
  await bp.fill('[data-testid=login-password]', 'wrong');
  await bp.click('[data-testid=login-submit]');
  await bp.waitForSelector('[data-testid=error]', { timeout: 8000 }).catch(() => {});
  ok(await bp.isVisible('[data-testid=error]') && (await bp.$$('[data-testid=board]')).length === 0, 'wrong password: error, no board');
  await bc.close();
  console.log(`PASS [${tag}] ${passed} checks`);
} catch (e) {
  console.log(`FAIL [${tag}] exception: ${e.message.split('\n')[0]}`);
  process.exit(1);
} finally {
  await browser.close();
}
