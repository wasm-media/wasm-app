// اختبار المهام والملفات والمدير (الشريحة 2) — Chromium آلي على Supabase حقيقي (REAL فقط: Storage حقيقي).
// يشغّله tests/ci/run_real.sh بعد اختبار اللوحة، على القاعدة نفسها، بهويات: الشريك الأول، الموظف (أ)، موظف ب، المدير،
// وحساب موظف باسم دخول بلا بريد (D29). يفشل برمز خروج 1 عند أول بند لا يتحقق، ويحفظ لقطات إن طُلبت.
// البنود: 2أ-2 (الموظف أ يرى مهمتيه فقط بلا نص من مهمة ب ولا اسم عميل؛ الشريك ينفّذ أفعاله السبعة)،
//         2ب-1 (موظف ب عبر HTTP: تنزيل/سرد/رابط موقّع لملف أ = مرفوض)، 2ب-2 (رفع وتنزيل حقيقيان)، 2ج (المدير)، 2د (اسم الدخول).
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
import fs from 'node:fs';
const require = createRequire(import.meta.url);
const { chromium } = require(execSync('npm root -g').toString().trim() + '/playwright');

const BASE = process.env.BASE || 'http://127.0.0.1:8080';
const API = process.env.AUTH_URL;       // Supabase المحلي (Auth + REST + Storage)
const APIKEY = process.env.ANON_KEY || '';
const [W, H] = (process.env.VIEWPORT || '1440x900').split('x').map(Number);
const SHOTS = process.env.SHOTS;
const tag = `${W}x${H}/${process.env.LANG_UI || 'ar'}`;
let passed = 0;
function ok(cond, what) {
  if (!cond) { console.log(`FAIL [${tag}] ${what}`); process.exit(1); }
  passed++; console.log(`ok   [${tag}] ${what}`);
}
if (process.env.REAL !== '1' || !API) { console.log('FAIL tasks.spec needs REAL=1 and AUTH_URL'); process.exit(1); }
const noIndic = async (page, where) => ok(!/[٠-٩۰-۹]/.test(await page.evaluate(() => document.body.innerText + ' ' + [...document.querySelectorAll('input,textarea,select')].map((e) => e.value).join(' '))), `no Arabic-Indic digits (${where})`);
const noHScroll = async (page, where) => ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1
  && getComputedStyle(document.body).overflowX !== 'hidden'), `no page horizontal scroll (${where})`);
const shot = async (page, name) => { if (SHOTS) await page.screenshot({ path: `${SHOTS}/slice2-${tag.replace('/', '-')}-${name}.png`, fullPage: true }); };

async function login(browser, user, password = 'test-pass') {
  const ctx = await browser.newContext({ viewport: { width: W, height: H }, locale: 'ar', acceptDownloads: true });
  const page = await ctx.newPage();
  await page.goto(BASE + '/');
  await page.fill('[data-testid=login-email]', user);
  await page.fill('[data-testid=login-password]', password);
  await page.click('[data-testid=login-submit]');
  await page.waitForSelector('#app-view:not([hidden]), [data-testid=no-access]:not([hidden])', { timeout: 10000 }).catch(() => {});
  return { ctx, page };
}
const token = (page) => page.evaluate(() => JSON.parse(localStorage.getItem('wasm.session')).access_token);
// نداء خام بهوية صفحة ما (لا عبر الواجهة): الحكم للسيرفر وحده
const raw = (page, path, init = {}) => page.evaluate(async ([api, key, p, i]) => {
  const tok = JSON.parse(localStorage.getItem('wasm.session')).access_token;
  const r = await fetch(`${api}${p}`, { ...i, headers: { apikey: key, authorization: `Bearer ${tok}`, 'content-type': 'application/json', ...(i.headers || {}) } });
  let body = ''; try { body = await r.text(); } catch { /* لا جسم */ }
  return { status: r.status, body };
}, [API, APIKEY, path, init]);
const taskIds = (page) => page.$$eval('[data-testid^=task-]', (els) => els.map((e) => e.getAttribute('data-testid')).filter((t) => /^task-\d+$/.test(t)).map((t) => Number(t.slice(5))));
async function waitStatus(page, id, label) {
  await page.waitForFunction(([n, l]) => document.querySelector(`[data-testid=task-status-${n}]`)?.textContent === l, [id, label], { timeout: 8000 }).catch(() => {});
  return page.evaluate((n) => document.querySelector(`[data-testid=task-status-${n}]`)?.textContent, id);
}
async function tabTasks(page) {
  if (await page.$('[data-testid=tab-tasks]')) await page.click('[data-testid=tab-tasks]');
  await page.waitForSelector('[data-testid=tasks-view]:not([hidden])', { timeout: 8000 });
}
async function newTask(page, { job, title, assignee, due }) {
  await page.click('[data-testid=new-task]');
  await page.waitForSelector('#task-dialog[open]', { timeout: 8000 });
  await page.selectOption('[data-testid=tf-job]', String(job));
  await page.fill('[data-testid=tf-title]', title);
  await page.selectOption('[data-testid=tf-assignee]', { label: assignee });
  if (due) await page.fill('[data-testid=tf-due]', due);
  const before = new Set(await taskIds(page));
  await page.click('[data-testid=tf-submit]');
  await page.waitForFunction((n) => document.querySelectorAll('[data-testid^=task-status-]').length > n, before.size, { timeout: 8000 }).catch(() => {});
  return (await taskIds(page)).find((id) => !before.has(id));
}
const cardText = (page, id) => page.textContent(`[data-testid=task-${id}]`);

const PDF = Buffer.from('%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n' + 'x'.repeat(2000));
const browser = await chromium.launch({ args: [`--lang=${process.env.LANG_UI || 'ar'}`] });
try {
  // ===== الشريك: شغلة جديدة من اللوحة، ثم ثلاث مهام من «المهام» =====
  const P = await login(browser, 'partner1@wasm.test');
  const pp = P.page;
  await pp.waitForSelector('[data-testid=board]:visible', { timeout: 8000 });
  await pp.click('[data-testid=new-job]');
  await pp.fill('[data-testid=nj-client]', 'مطبعة الأمل السرية');
  await pp.fill('[data-testid=nj-title]', 'بروشور الافتتاح');
  await pp.selectOption('[data-testid=nj-type]', 'print');
  await pp.click('[data-testid=nj-submit]');
  await pp.waitForFunction(() => [...document.querySelectorAll('[data-stage=intake] .client')].some((e) => e.textContent === 'مطبعة الأمل السرية'), null, { timeout: 8000 });
  const job = await pp.evaluate(() => Math.max(...[...document.querySelectorAll('[data-testid^=card-]')].map((e) => Number((e.getAttribute('data-testid').match(/^card-(\d+)$/) || [])[1] || 0))));
  ok(job >= 9001, `partner opens job #${job}`);

  await tabTasks(pp);
  ok(await pp.isVisible('[data-testid=new-task]'), 'partner sees «مهمة جديدة»');
  const tA1 = await newTask(pp, { job, title: 'تصميم الغلاف', assignee: 'موظف', due: '10/10/2026' });
  const tA2 = await newTask(pp, { job, title: 'تصميم الظهر', assignee: 'موظف' });
  const tB = await newTask(pp, { job, title: 'مهمة ب السرية', assignee: 'موظف ب' });
  ok(tA1 && tA2 && tB && new Set([tA1, tA2, tB]).size === 3, `partner action 1/7: add 3 tasks (${tA1}, ${tA2}, ${tB})`);
  ok((await cardText(pp, tA1)).includes('10/10/2026') && (await cardText(pp, tA1)).includes('المكلَّف: موظف'), 'task card: due date dd/mm/yyyy + assignee name');
  // تعديل
  await pp.click(`[data-testid=task-edit-${tB}]`);
  await pp.fill('[data-testid=tf-title]', 'مهمة ب السرية المعدّلة');
  await pp.click('[data-testid=tf-submit]');
  await pp.waitForFunction((n) => document.querySelector(`[data-testid=task-title-${n}]`)?.textContent === 'مهمة ب السرية المعدّلة', tB, { timeout: 8000 }).catch(() => {});
  ok(await pp.textContent(`[data-testid=task-title-${tB}]`) === 'مهمة ب السرية المعدّلة', 'partner action 2/7: edit task');
  await noIndic(pp, 'partner tasks');
  await noHScroll(pp, 'partner tasks');
  await shot(pp, 'partner-tasks');

  // ===== الموظف أ: مهمتاه فقط، بلا عميل ولا مهمة ب =====
  const A = await login(browser, 'employee@wasm.test');
  const ap = A.page;
  await ap.waitForSelector(`[data-testid=task-${tA1}]`, { timeout: 8000 }).catch(() => {});
  const aIds = (await taskIds(ap)).sort();
  ok(JSON.stringify(aIds) === JSON.stringify([tA1, tA2].sort()), `2A-2 employee A sees exactly his 2 tasks (got ${aIds})`);
  const aText = await ap.evaluate(() => document.body.innerText);
  ok(!aText.includes('مهمة ب') && !aText.includes('مطبعة الأمل') && !aText.includes('موظف ب'), '2A-2 no text from task B, no client name');
  ok(aText.includes(`#${job}`) && aText.includes('بروشور الافتتاح'), 'employee sees job number + title inside the task');
  ok((await ap.$$('[data-testid=board], [data-testid=tab-board]')).length === 0 && !(await ap.isVisible('[data-testid=new-task]')), 'employee: no board, no tabs, no «مهمة جديدة»');
  ok(!(await ap.$(`[data-testid=task-edit-${tA1}]`)) && !(await ap.$(`[data-testid=task-assign-${tA1}]`)) && !(await ap.$(`[data-testid=task-cancel-${tA1}]`)), 'employee: no edit/reassign/cancel buttons');
  await ap.click(`[data-testid=task-start-${tA1}]`);
  ok(await waitStatus(ap, tA1, 'قيد العمل') === 'قيد العمل', 'employee starts: جديدة ← قيد العمل');
  // رفع ملف حقيقي إلى Storage ثم تنزيله
  await ap.click(`[data-testid=task-files-${tA1}] summary`);
  await ap.selectOption(`[data-testid=task-kind-${tA1}]`, 'draft');
  await ap.setInputFiles(`[data-testid=task-upload-${tA1}]`, { name: 'غلاف-مسودة.pdf', mimeType: 'application/pdf', buffer: PDF });
  await ap.waitForSelector(`[data-testid=task-files-${tA1}] [data-testid^=file-dl-]`, { timeout: 15000 }).catch(() => {});
  const fileId = await ap.evaluate((n) => Number(document.querySelector(`[data-testid=task-files-${n}] [data-testid^=file-dl-]`)?.getAttribute('data-testid').slice(8)), tA1);
  ok(fileId > 0 && (await ap.textContent(`[data-testid=file-${fileId}]`)).includes('غلاف-مسودة.pdf'), '2B-2 employee uploads a PDF to real Storage');
  const [dl] = await Promise.all([ap.waitForEvent('download', { timeout: 10000 }), ap.click(`[data-testid=file-dl-${fileId}]`)]);
  const got = fs.readFileSync(await dl.path());
  ok(dl.suggestedFilename() === 'غلاف-مسودة.pdf' && got.equals(PDF), `2B-2 employee downloads the same bytes with the original name (${dl.suggestedFilename()}, ${got.length}/${PDF.length} bytes)`);
  await ap.setInputFiles(`[data-testid=task-upload-${tA1}]`, { name: 'شعار.svg', mimeType: 'image/svg+xml', buffer: Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"/>') });
  await ap.waitForSelector('[data-testid=error]:not([hidden])', { timeout: 8000 }).catch(() => {});
  ok((await ap.textContent('[data-testid=error]')).includes('نوع الملف'), 'SVG refused with a clear message');
  // والسيرفر يرفضه حتى لو تجاوز أحد الواجهة
  const svgSrv = await raw(ap, '/rest/v1/rpc/begin_task_upload', { method: 'POST', body: JSON.stringify({ p_task: tA1, p_name: 'x.svg', p_mime: 'image/svg+xml', p_size: 10, p_kind: 'draft' }) });
  ok(svgSrv.status >= 400 && svgSrv.body.includes('file_type'), `server refuses SVG (${svgSrv.status})`);
  const objPath = JSON.parse((await raw(ap, `/rest/v1/task_files?select=object_path&id=eq.${fileId}`)).body)[0].object_path;
  ok(/^t\d+\/[0-9a-f-]{36}\.pdf$/.test(objPath), 'object path is server-made');
  await ap.click(`[data-testid=task-submit-${tA1}]`);
  ok(await waitStatus(ap, tA1, 'جاهزة للمراجعة') === 'جاهزة للمراجعة', 'employee submits: قيد العمل ← جاهزة للمراجعة');
  ok(!(await ap.$(`[data-testid=task-approve-${tA1}]`)), 'employee cannot approve his own task (no button)');
  await noIndic(ap, 'employee tasks');
  await noHScroll(ap, 'employee tasks');
  await shot(ap, 'employee-tasks');

  // ===== موظف ب عبر HTTP بهويته: لا تنزيل ولا سرد ولا رابط موقّع لملف أ =====
  const B = await login(browser, 'employee2@wasm.test');
  const bp = B.page;
  await bp.waitForSelector(`[data-testid=task-${tB}]`, { timeout: 8000 }).catch(() => {});
  ok(JSON.stringify(await taskIds(bp)) === JSON.stringify([tB]), 'employee B sees only his task');
  const bGet = await raw(bp, `/storage/v1/object/authenticated/task-files/${objPath}`, { method: 'GET' });
  ok(bGet.status !== 200 && !bGet.body.includes('%PDF'), `2B-1 employee B direct download of A's file refused (${bGet.status})`);
  const bList = await raw(bp, '/storage/v1/object/list/task-files', { method: 'POST', body: JSON.stringify({ prefix: objPath.split('/')[0], limit: 100 }) });
  ok(!bList.body.includes(objPath.split('/')[1]), `2B-1 employee B listing does not show A's file (${bList.status})`);
  const bSign = await raw(bp, `/storage/v1/object/sign/task-files/${objPath}`, { method: 'POST', body: JSON.stringify({ expiresIn: 60 }) });
  ok(bSign.status !== 200 && !bSign.body.includes('signedURL'), `2B-1 employee B signed link for A's file refused (${bSign.status})`);
  const bPut = await raw(bp, `/storage/v1/object/task-files/${objPath}`, { method: 'PUT', body: 'overwrite', headers: { 'content-type': 'application/pdf', 'x-upsert': 'true' } });
  const aAgain = await raw(ap, `/storage/v1/object/authenticated/task-files/${objPath}`, { method: 'GET' });
  ok(bPut.status !== 200 && aAgain.status === 200 && aAgain.body.startsWith('%PDF'), `employee B cannot overwrite A's file (${bPut.status})`);
  const aDel = await raw(ap, '/storage/v1/object/task-files', { method: 'DELETE', body: JSON.stringify({ prefixes: [objPath] }) });
  const aStill = await raw(ap, `/storage/v1/object/authenticated/task-files/${objPath}`, { method: 'GET' });
  ok(aStill.status === 200, `I8 even the uploader cannot delete the file (delete ${aDel.status}, still there)`);
  const anon = await bp.evaluate(async ([api, key, p]) => (await fetch(`${api}/storage/v1/object/authenticated/task-files/${p}`, { headers: { apikey: key } })).status, [API, APIKEY, objPath]);
  ok(anon !== 200, `I5 no download without login (${anon})`);
  await B.ctx.close();

  // ===== الشريك: إعادة بملاحظة، اعتماد، اعتماد الملف، إعادة تكليف، إلغاء، السجل =====
  await pp.click('[data-testid=tab-tasks]');
  await pp.waitForSelector(`[data-testid=task-return-${tA1}]`, { timeout: 8000 }).catch(() => {});
  await pp.click(`[data-testid=task-return-${tA1}]`);
  await pp.fill('[data-testid=reason-text]', '   ');
  await pp.click('[data-testid=reason-confirm]');
  ok(await pp.isVisible('#reason-msg') && await waitStatus(pp, tA1, 'جاهزة للمراجعة') === 'جاهزة للمراجعة', 'blank return note refused before the server');
  await pp.fill('[data-testid=reason-text]', 'كبّر الشعار');
  await pp.click('[data-testid=reason-confirm]');
  ok(await waitStatus(pp, tA1, 'قيد العمل') === 'قيد العمل', 'partner action 3/7: return with a note → قيد العمل');
  await ap.reload();
  await ap.waitForSelector(`[data-testid=task-note-${tA1}]`, { timeout: 8000 }).catch(() => {});
  ok((await ap.textContent(`[data-testid=task-note-${tA1}]`) || '').includes('كبّر الشعار'), 'employee sees the review note on his task');
  await ap.click(`[data-testid=task-submit-${tA1}]`);
  await waitStatus(ap, tA1, 'جاهزة للمراجعة');
  await pp.click('[data-testid=tab-tasks]');
  await pp.waitForSelector(`[data-testid=task-approve-${tA1}]`, { timeout: 8000 }).catch(() => {});
  await pp.click(`[data-testid=task-approve-${tA1}]`);
  ok(await waitStatus(pp, tA1, 'منجزة') === 'منجزة', 'partner action 4/7: approve → منجزة');
  await pp.click('[data-testid=group-done]');   // المنجزة مطويّة افتراضيًا
  await pp.click(`[data-testid=task-files-${tA1}] summary`);
  await pp.click(`[data-testid=file-approve-${fileId}]`);
  await pp.waitForSelector(`[data-testid=file-approved-${fileId}]`, { timeout: 8000 }).catch(() => {});
  ok(await pp.isVisible(`[data-testid=file-approved-${fileId}]`), 'partner approves the file');
  await pp.click(`[data-testid=task-assign-${tA2}]`);
  await pp.selectOption('[data-testid=assign-select]', { label: 'موظف ب' });
  await pp.click('[data-testid=assign-confirm]');
  await pp.waitForFunction((n) => document.querySelector(`[data-testid=task-assignee-${n}]`)?.textContent.includes('موظف ب'), tA2, { timeout: 8000 }).catch(() => {});
  ok((await pp.textContent(`[data-testid=task-assignee-${tA2}]`)).includes('موظف ب'), 'partner action 5/7: reassign A → B');
  await pp.click(`[data-testid=task-cancel-${tB}]`);
  await pp.fill('[data-testid=reason-text]', 'العميل ألغى الظهر');
  await pp.click('[data-testid=reason-confirm]');
  ok(await waitStatus(pp, tB, 'ملغاة') === 'ملغاة', 'partner action 6/7: cancel with a reason');
  await pp.click(`[data-testid=task-log-${tA1}]`);
  await pp.waitForSelector('[data-testid=task-log-panel] [data-testid=task-log-row]', { timeout: 8000 }).catch(() => {});
  const rows = await pp.$$eval('[data-testid=task-log-panel] [data-testid=task-log-row]', (els) => els.map((e) => e.innerText));
  const today = new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Hebron', day: '2-digit', month: '2-digit', year: 'numeric' }).format(new Date());
  ok(rows.length === 6 && rows[0].includes('موظف') && rows.some((r) => r.includes('كبّر الشعار')) && rows.every((r) => r.includes(today)),
    `partner action 7/7: task log — 6 lines, names, note, today ${today} (got ${rows.length})`);
  await noIndic(pp, 'task log');
  await shot(pp, 'task-log');
  await pp.click('[data-testid=task-log-close]');
  // الموظف أ بعد السحب: مهمته المنجزة فقط
  await ap.reload();
  await ap.waitForSelector('[data-testid=tasks-view]:not([hidden])', { timeout: 8000 });
  await ap.waitForTimeout(500);
  ok(JSON.stringify(await taskIds(ap)) === JSON.stringify([tA1]), 'after reassign employee A no longer sees the task');

  // ===== المدير: اللوحة للقراءة فقط، ويضيف مهمة لموظف، ولا يرى الشريكين في التكليف =====
  const M = await login(browser, 'manager@wasm.test');
  const mp = M.page;
  await mp.waitForSelector('[data-testid=tasks-view]:not([hidden])', { timeout: 8000 }).catch(() => {});
  ok(await mp.isVisible('[data-testid=tasks-view]') && (await taskIds(mp)).length >= 3, 'manager sees all tasks');
  await mp.click('[data-testid=tab-board]');
  await mp.waitForSelector(`[data-testid=card-${job}]:visible`, { timeout: 8000 }).catch(() => {});
  ok(await mp.isVisible(`[data-testid=card-${job}]`), 'manager sees the board with the job');
  ok(!(await mp.$('[data-testid=new-job]')) && (await mp.$$('[data-testid^=card-next-], [data-testid^=card-cancel-], [data-testid^=card-log-]')).length === 0,
    '2C manager board is read-only (no new job, no move, no cancel, no stage log)');
  await tabTasks(mp);
  await mp.click('[data-testid=new-task]');
  await mp.waitForSelector('#task-dialog[open]', { timeout: 8000 });
  const opts = await mp.$$eval('[data-testid=tf-assignee] option', (os) => os.map((o) => o.textContent));
  ok(opts.includes('موظف') && opts.includes('المدير') && !opts.includes('الشريك الأول') && !opts.includes('الشريك الثاني'), '2C manager can assign staff only, not partners');
  await mp.click('#task-dialog [data-close]');
  const tM = await newTask(mp, { job, title: 'مهمة من المدير', assignee: 'موظف', due: '01/11/2026' });
  ok(tM > 0, 'manager adds a task');
  await noHScroll(mp, 'manager tasks');
  await shot(mp, 'manager-tasks');
  await M.ctx.close();

  // ===== D29: الدخول باسم مستخدم (بلا بريد) =====
  const S = await login(browser, 'test.user', 'test.user');
  ok(await S.page.isVisible('[data-testid=tasks-view]') && (await S.page.textContent('#tasks-heading')) === 'مهامي'
    && (await S.page.textContent('#who-name')) === 'موظف باسم دخول', '2D login with a username (no email) → «مهامي» with the seeded name');
  await S.ctx.close();
  const S2 = await login(browser, 'test.user', 'wrong-pass');
  ok(await S2.page.isVisible('[data-testid=login-email]') && (await S2.page.textContent('[data-testid=error]')).includes('اسم الدخول'), 'wrong username password: clear message');
  await S2.ctx.close();
  await A.ctx.close(); await P.ctx.close();
  console.log(`PASS [${tag}] ${passed} checks`);
} catch (e) {
  console.log(`FAIL [${tag}] exception: ${e.message.split('\n')[0]}`);
  process.exit(1);
} finally {
  await browser.close();
}
