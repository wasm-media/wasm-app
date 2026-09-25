// لوحة الشغلات — وسم ميديا (الشريحة 1ب)
// الواجهة لا تقرر شيئًا: كل صلاحية وكل قاعدة مفروضة في السيرفر (الشريحة 1أ). هنا عرض ورسائل واضحة فقط.
// كل نص من القاعدة يُكتب بـ textContent — لا innerHTML لبيانات المستخدم.

const CFG = window.WASM_CONFIG || {};
const BASE = (CFG.url || location.origin).replace(/\/$/, '');
const STORE = 'wasm.session';

const STAGES = [
  ['intake', 'استقبال'], ['quote', 'عرض سعر'], ['client_approval', 'موافقة العميل'], ['design', 'تصميم'],
  ['review', 'مراجعة'], ['execution', 'تنفيذ'], ['delivered', 'تسليم'],
];
const STAGE_LABEL = Object.fromEntries([...STAGES, ['cancelled', 'ملغاة']]);
const TYPE_LABEL = { design: 'تصميم', print: 'طباعة', video: 'فيديو', event: 'فعالية', other: 'أخرى' };
const BACKABLE = new Set(['quote', 'client_approval', 'design', 'review', 'execution']);
const ERRORS = {
  not_partner: 'لا توجد لك صلاحية على هذه العملية.',
  stale_stage: 'تغيّرت الشغلة من شخص آخر قبل طلبك. حدّثنا اللوحة — راجعها وأعد المحاولة.',
  final_stage: 'الشغلة مسلّمة أو ملغاة، ولا تتحرك بعد ذلك.',
  invalid_transition: 'هذه النقلة غير مسموحة.',
  reason_required: 'اكتب سبب الإلغاء.',
  client_required: 'اكتب اسم العميل.',
  title_required: 'اكتب عنوان الشغلة.',
  invalid_type: 'اختر نوع الشغلة.',
  job_not_found: 'الشغلة غير موجودة.',
  invalid_login: 'البريد أو كلمة المرور غير صحيحة.',
  network: 'تعذّر الاتصال بالخادم. تأكد من الإنترنت وأعد المحاولة.',
  bad_date: 'اكتب التاريخ بصيغة يوم/شهر/سنة، مثل 05/10/2026.',
  logout_failed: 'تعذّر تسجيل الخروج من الخادم، فالجلسة ما زالت فعّالة. تأكد من الاتصال واضغط «خروج» مرة أخرى.',
};

const $ = (id) => document.getElementById(id);
function el(tag, props = {}, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === 'text') e.textContent = v;
    else if (k === 'class') e.className = v;
    else if (k === 'dataset') Object.assign(e.dataset, v);
    else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
    else e.setAttribute(k, v);
  }
  for (const c of kids) if (c) e.append(c);
  return e;
}

// ===== التواريخ بأرقام إنجليزية: 25/09/2026 =====
function fmtDate(iso) { // 'YYYY-MM-DD'
  if (!iso) return '';
  const [y, m, d] = iso.split('-');
  return `${d}/${m}/${y}`;
}
const dtf = new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Hebron', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
function fmtStamp(ts) {
  const p = Object.fromEntries(dtf.formatToParts(new Date(ts)).map((x) => [x.type, x.value]));
  return `${p.day}/${p.month}/${p.year} · ${p.hour}:${p.minute}`;
}

// حقل التاريخ نصّي يتحكم به التطبيق (حقل المتصفح يعرض الصيغة بلغة الجهاز: شهر قبل يوم أو أرقام هندية)
const toLatinDigits = (t) => t.replace(/[٠-٩]/g, (d) => String('٠١٢٣٤٥٦٧٨٩'.indexOf(d))).replace(/[۰-۹]/g, (d) => String('۰۱۲۳۴۵۶۷۸۹'.indexOf(d)));
function parseDue(text) { // '05/10/2026' → '2026-10-05' · فارغ → null · غير ذلك يرمي bad_date
  const t = toLatinDigits(text).trim();
  if (!t) return null;
  const m = t.match(/^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})$/);
  if (!m) throw new AppError('bad_date');
  const [d, mo, y] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const dt = new Date(Date.UTC(y, mo - 1, d));
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== mo - 1 || dt.getUTCDate() !== d) throw new AppError('bad_date');
  return `${y}-${String(mo).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
}

// ===== الجلسة =====
let session = null;
try { session = JSON.parse(localStorage.getItem(STORE) || 'null'); } catch { session = null; }
function saveSession(s) {
  session = s;
  try { s ? localStorage.setItem(STORE, JSON.stringify(s)) : localStorage.removeItem(STORE); } catch { /* تخزين غير متاح: الجلسة في الذاكرة فقط */ }
}
async function authToken(params, body) {
  const r = await fetch(`${BASE}/auth/v1/token?${params}`, {
    method: 'POST', headers: { apikey: CFG.anonKey || '', 'content-type': 'application/json' }, body: JSON.stringify(body),
  });
  if (!r.ok) throw new AppError(r.status === 400 ? 'invalid_login' : 'network');
  const j = await r.json();
  return { access_token: j.access_token, refresh_token: j.refresh_token, expires_at: Date.now() + (j.expires_in - 60) * 1000, uid: j.user?.id };
}
async function refresh() {
  if (!session?.refresh_token) throw new AppError('invalid_login');
  saveSession(await authToken('grant_type=refresh_token', { refresh_token: session.refresh_token }));
}

class AppError extends Error { constructor(code) { super(code); this.code = code; } }

// ===== الاتصال بالقاعدة =====
async function api(path, { method = 'GET', body, retried = false } = {}) {
  if (session && Date.now() > session.expires_at) await refresh();
  let r;
  try {
    r = await fetch(`${BASE}/rest/v1/${path}`, {
      method,
      headers: { apikey: CFG.anonKey || '', authorization: `Bearer ${session?.access_token || CFG.anonKey || ''}`, 'content-type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch { throw new AppError('network'); }
  if (r.status === 401 && !retried && session) { await refresh(); return api(path, { method, body, retried: true }); }
  const text = await r.text();
  const data = text ? JSON.parse(text) : null;
  if (!r.ok) throw new AppError((data && data.message) || 'network');
  return data;
}
const rpc = (fn, args) => api(`rpc/${fn}`, { method: 'POST', body: args });

// ===== الرسائل =====
let toastTimer;
function showError(err) {
  const code = err instanceof AppError ? err.code : 'network';
  const t = $('error');
  t.textContent = ERRORS[code] || 'حدث خطأ غير متوقع.';
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, 7000);
}

// ===== العرض =====
function show(view) {
  for (const id of ['login-view', 'no-access', 'board-view']) if ($(id)) $(id).hidden = id !== view;
  $('who').hidden = view === 'login-view';
}

let jobs = [];
let busy = false;

function card(job) {
  const n = job.job_number;
  const actions = el('div', { class: 'card-actions' });
  const act = (label, testid, cls, fn) => actions.append(el('button', { type: 'button', class: cls, 'data-testid': `${testid}-${n}`, text: label, onclick: fn }));
  if (job.stage !== 'cancelled' && job.stage !== 'delivered') {
    const i = STAGES.findIndex(([s]) => s === job.stage);
    act(`← ${STAGES[i + 1][1]}`, 'card-next', 'btn-step', () => move(job, STAGES[i + 1][0]));
    if (BACKABLE.has(job.stage)) act(`${STAGES[i - 1][1]} →`, 'card-back', 'btn-quiet', () => move(job, STAGES[i - 1][0]));
    act('إلغاء', 'card-cancel', 'btn-quiet danger', () => openCancel(job));
  }
  act('السجل', 'card-log', 'btn-quiet', () => openLog(job));
  return el('article', { class: `card type-${job.job_type}`, 'data-testid': `card-${n}` },
    el('div', { class: 'card-top' },
      el('span', { class: 'num', text: `#${n}` }),
      el('span', { class: 'tag', text: TYPE_LABEL[job.job_type] || job.job_type })),
    el('div', { class: 'client', text: job.client }),
    el('div', { class: 'title', text: job.title }),
    job.due_date ? el('div', { class: 'due', text: `التسليم ${fmtDate(job.due_date)}` }) : null,
    actions);
}

function render() {
  const board = $('board');
  board.replaceChildren();
  for (const [stage, label] of STAGES) {
    const list = jobs.filter((j) => j.stage === stage);
    const body = el('div', { class: 'col-body' });
    for (const j of list) body.append(card(j));
    if (!list.length) body.append(el('div', { class: 'col-empty', text: '—' }));
    board.append(el('section', { class: `col col-${stage}`, 'data-stage': stage },
      el('header', { class: 'col-head' },
        el('span', { 'data-testid': 'col-title', text: label }),
        el('span', { class: 'count', text: String(list.length) })),
      body));
  }
  const cancelled = jobs.filter((j) => j.stage === 'cancelled');
  $('cancelled-list').replaceChildren(...cancelled.map(card));
  if (!cancelled.length) $('cancelled-list').append(el('div', { class: 'col-empty', text: 'لا توجد شغلات ملغاة.' }));
  $('cancelled-count').textContent = String(cancelled.length);
  $('open-count').textContent = String(jobs.filter((j) => !['cancelled', 'delivered'].includes(j.stage)).length);
}

async function loadBoard() {
  jobs = await api('jobs?select=job_number,client,title,job_type,due_date,stage&order=job_number.desc');
  render();
}

async function guarded(fn) {
  if (busy) return;
  busy = true; document.body.classList.add('busy');
  try { await fn(); } catch (e) { showError(e); } finally { busy = false; document.body.classList.remove('busy'); }
}

function move(job, to) {
  return guarded(async () => {
    try { await rpc('move_job', { p_job: job.job_number, p_from: job.stage, p_to: to }); }
    catch (e) { await loadBoard(); throw e; } // اللوحة تتحدّث دائمًا بعد الرفض لتعرض الحالة الحقيقية
    await loadBoard();
  });
}

// ===== شغلة جديدة =====
function openNewJob() {
  const f = $('new-job-form'); f.reset(); $('nj-msg').hidden = true;
  $('new-job-dialog').showModal();
  f.elements.client.focus();
}
$('new-job-form').elements.due.addEventListener('input', (ev) => { // أرقام إنجليزية دائمًا في الحقل
  const v = toLatinDigits(ev.target.value); if (v !== ev.target.value) ev.target.value = v;
});
$('new-job-form').addEventListener('submit', (ev) => {
  ev.preventDefault();
  const f = ev.target.elements;
  guarded(async () => {
    try {
      const due = parseDue(f.due.value);
      await rpc('create_job', { p_client: f.client.value, p_title: f.title.value, p_type: f.type.value, p_due: due, p_notes: f.notes.value || null });
    } catch (e) { $('nj-msg').textContent = ERRORS[e.code] || ERRORS.network; $('nj-msg').hidden = false; return; }
    $('new-job-dialog').close();
    await loadBoard();
  });
});

// ===== الإلغاء =====
let cancelJob = null;
function openCancel(job) {
  cancelJob = job;
  $('cancel-num').textContent = `#${job.job_number}`;
  $('cancel-reason').value = ''; $('cancel-msg').hidden = true;
  $('cancel-dialog').showModal();
}
$('cancel-form').addEventListener('submit', (ev) => {
  ev.preventDefault();
  const reason = $('cancel-reason').value;
  if (!/[\p{L}\p{N}]/u.test(reason)) { $('cancel-msg').textContent = ERRORS.reason_required; $('cancel-msg').hidden = false; return; }
  guarded(async () => {
    try { await rpc('cancel_job', { p_job: cancelJob.job_number, p_from: cancelJob.stage, p_reason: reason }); }
    catch (e) { $('cancel-dialog').close(); await loadBoard(); throw e; }
    $('cancel-dialog').close();
    await loadBoard();
  });
});

// ===== السجل =====
let people = null;
async function openLog(job) {
  await guarded(async () => {
    const [rows, ppl, notes] = await Promise.all([
      api(`job_stage_log?select=from_stage,to_stage,moved_by,moved_at,reason&job_number=eq.${job.job_number}&order=id.asc`),
      people ? Promise.resolve(people) : api('people?select=user_id,display_name'),
      api(`job_notes?select=body&job_number=eq.${job.job_number}`),
    ]);
    people = ppl;
    const name = Object.fromEntries(ppl.map((p) => [p.user_id, p.display_name]));
    $('log-num').textContent = `#${job.job_number}`;
    $('log-meta').replaceChildren(
      el('div', { class: 'client', text: job.client }), el('div', { class: 'title', text: job.title }),
      el('div', { class: 'state', text: `المرحلة الحالية: ${STAGE_LABEL[job.stage]}` }),
      notes[0] ? el('div', { class: 'notes', text: `ملاحظات: ${notes[0].body}` }) : null);
    const list = $('log-list');
    list.replaceChildren(...rows.map((r) => el('li', { 'data-testid': 'log-row', class: r.to_stage === 'cancelled' ? 'is-cancel' : '' },
      el('div', { class: 'move', text: `${STAGE_LABEL[r.from_stage]} ← ${STAGE_LABEL[r.to_stage]}` }),
      el('div', { class: 'by', text: `${name[r.moved_by] || 'مستخدم غير معروف'} · ${fmtStamp(r.moved_at)}` }),
      r.reason ? el('div', { class: 'reason', text: `السبب: ${r.reason}` }) : null)));
    if (!rows.length) list.append(el('li', { class: 'col-empty', text: 'لم تتحرك الشغلة بعد.' }));
    $('log-dialog').showModal();
  });
}

// ===== الدخول والخروج =====
async function enter() {
  try {
    const partner = await rpc('is_partner', {});
    if (!partner) { show('no-access'); $('who-name').textContent = ''; return; } // غير الشريك: لا تُنشأ عناصر اللوحة أصلًا
    if (!$('board-view')) {
      $('main').append($('board-tpl').content.cloneNode(true));
      $('new-job').addEventListener('click', openNewJob);
    }
    show('board-view');
    await loadBoard();
    try {
      const me = await api(`people?select=display_name&user_id=eq.${session.uid}`);
      $('who-name').textContent = me[0]?.display_name || '';
    } catch { /* الاسم اختياري في الشريط */ }
  } catch (e) {
    if (e.code === 'invalid_login') { saveSession(null); show('login-view'); return; }
    showError(e);
  }
}
$('login-form').addEventListener('submit', (ev) => {
  ev.preventDefault();
  guarded(async () => {
    saveSession(await authToken('grant_type=password', { email: $('login-email').value.trim(), password: $('login-password').value }));
    $('login-password').value = '';
    await enter();
  });
});
$('logout').addEventListener('click', () => guarded(async () => {
  // I13: الخروج يُبطل الجلسة في الخادم فعلًا. رمز الدخول المنتهي يرفضه Supabase Auth (403) فلا يُبطَل شيء،
  // لذلك يُجدَّد أولًا. وأي فشل يظهر للمستخدم ولا يُعرض خروج ناجح؛ الجلسة تبقى ليعيد المحاولة.
  if (session) {
    try {
      if (Date.now() > session.expires_at) await refresh();
      const out = () => fetch(`${BASE}/auth/v1/logout?scope=local`, { method: 'POST', headers: { apikey: CFG.anonKey || '', authorization: `Bearer ${session.access_token}` } });
      let r = await out();
      if (r.status === 401 || r.status === 403) { await refresh(); r = await out(); }
      if (!(r.ok || r.status === 404)) throw new AppError('logout_failed');
    } catch (e) {
      // رمز التجديد مرفوض أصلًا = الجلسة ميتة في الخادم، فلا شيء يُبطَل؛ غير ذلك فشل ظاهر
      if (!(e instanceof AppError && e.code === 'invalid_login')) throw new AppError('logout_failed');
    }
  }
  saveSession(null);
  location.reload();
}));
for (const b of document.querySelectorAll('[data-close]')) b.addEventListener('click', () => b.closest('dialog').close());

if (session) enter(); else show('login-view');
