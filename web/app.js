// لوحة الشغلات والمهام — وسم ميديا (الشريحة 1ب + الشريحة 2)
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
  invalid_login: 'اسم الدخول أو كلمة المرور غير صحيحة.',
  open_tasks: 'على الشغلة مهام غير منجزة. أنجزها أو ألغها قبل التسليم.',
  not_allowed: 'لا توجد لك صلاحية على هذه العملية.',
  job_closed: 'الشغلة مسلّمة أو ملغاة، فلا تُضاف لها مهام.',
  task_not_found: 'المهمة غير موجودة أو لم تعد مكلَّفًا بها. حدّثنا القائمة.',
  invalid_assignee: 'اختر شخصًا آخر لهذه المهمة.',
  stale_status: 'تغيّرت المهمة من شخص آخر قبل طلبك. حدّثنا القائمة — راجعها وأعد المحاولة.',
  final_status: 'المهمة منجزة أو ملغاة، ولا تتغير بعد ذلك.',
  invalid_transition: 'هذه النقلة غير مسموحة.',
  note_required: 'اكتب ملاحظة الإعادة.',
  own_review: 'لا تعتمد مهمة مكلَّفًا أنت بها. يعتمدها أحد الشريكين.',
  job_required: 'اختر الشغلة.',
  assignee_required: 'اختر المكلَّف.',
  file_type: 'نوع الملف غير مسموح. المسموح: PDF أو JPG أو PNG أو WEBP أو MP4 أو ZIP.',
  file_too_large: 'الملف أكبر من 50MB. اتركه في مكانه المعتاد وضع رابطه في وصف المهمة.',
  file_empty: 'الملف فارغ.',
  file_not_found: 'الملف غير موجود.',
  upload_missing: 'لم يكتمل رفع الملف. أعد المحاولة.',
  upload_failed: 'تعذّر رفع الملف. أعد المحاولة.',
  download_failed: 'تعذّر تنزيل الملف. أعد المحاولة.',
  already_approved: 'الملف معتمد من قبل.',
  network: 'تعذّر الاتصال بالخادم. تأكد من الإنترنت وأعد المحاولة.',
  bad_date: 'اكتب التاريخ بصيغة يوم/شهر/سنة، مثل 05/10/2026.',
  invite_invalid: 'رابط الدعوة منتهي أو استُعمل من قبل. اطلب رابطًا جديدًا.',
  password_short: 'كلمة السر 8 أحرف على الأقل.',
  password_mismatch: 'كلمتا السر غير متطابقتين.',
  weak_password: 'كلمة السر ضعيفة. اختر كلمة أطول وأصعب.',
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
  for (const id of ['login-view', 'setpw-view', 'no-access', 'app-view']) if ($(id)) $(id).hidden = id !== view;
  $('who').hidden = view === 'login-view' || view === 'setpw-view';
}

let jobs = [];
let busy = false;

function card(job) {
  const n = job.job_number;
  const actions = el('div', { class: 'card-actions' });
  const act = (label, testid, cls, fn) => actions.append(el('button', { type: 'button', class: cls, 'data-testid': `${testid}-${n}`, text: label, onclick: fn }));
  if (me?.role === 'partner' && job.stage !== 'cancelled' && job.stage !== 'delivered') {
    const i = STAGES.findIndex(([s]) => s === job.stage);
    act(`← ${STAGES[i + 1][1]}`, 'card-next', 'btn-step', () => move(job, STAGES[i + 1][0]));
    if (BACKABLE.has(job.stage)) act(`${STAGES[i - 1][1]} →`, 'card-back', 'btn-quiet', () => move(job, STAGES[i - 1][0]));
    act('إلغاء', 'card-cancel', 'btn-quiet danger', () => openCancel(job));
  }
  if (me?.role === 'partner') act('السجل', 'card-log', 'btn-quiet', () => openLog(job)); // المدير لا يقرأ الملاحظات ولا سجل المراحل
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
let me = null; // { role, display_name } من السيرفر (whoami)
function mountApp() {
  if ($('app-view')) return;
  const app = el('section', { id: 'app-view' });
  $('main').append(app);
  const manages = me.role === 'partner' || me.role === 'manager';
  if (manages) {
    app.append($('nav-tpl').content.cloneNode(true));
    for (const b of app.querySelectorAll('[data-tab]')) b.addEventListener('click', () => guarded(() => openTab(b.dataset.tab)));
    app.append($('board-tpl').content.cloneNode(true));
    if (me.role === 'partner') $('new-job').addEventListener('click', openNewJob);
    else $('new-job').remove(); // المدير: اللوحة للقراءة فقط
  }
  app.append($('tasks-tpl').content.cloneNode(true));
  $('tasks-heading').textContent = manages ? 'المهام' : 'مهامي';
  if (manages) { $('new-task').hidden = false; $('new-task').addEventListener('click', () => guarded(openNewTask)); }
}
let tab = 'tasks';
async function openTab(name) {
  tab = name;
  if ($('board-view')) $('board-view').hidden = name !== 'board';
  $('tasks-view').hidden = name !== 'tasks';
  for (const b of document.querySelectorAll('[data-tab]')) b.classList.toggle('active', b.dataset.tab === name);
  $('brand-page').textContent = name === 'board' ? 'لوحة الشغلات' : 'المهام';
  try { localStorage.setItem('wasm.tab', name); } catch { /* اختياري */ }
  if (name === 'board') await loadBoard(); else await loadTasks();
}
async function enter() {
  try {
    const rows = await rpc('whoami', {});
    me = rows && rows[0] ? rows[0] : null;
    if (!me) { show('no-access'); $('who-name').textContent = ''; return; } // بلا دور: لا تُنشأ أي شاشة بيانات أصلًا
    $('who-name').textContent = me.display_name || '';
    mountApp();
    show('app-view');
    let first = me.role === 'partner' ? 'board' : 'tasks';
    if (me.role !== 'employee') { try { first = localStorage.getItem('wasm.tab') || first; } catch { /* اختياري */ } }
    await openTab(me.role === 'employee' ? 'tasks' : first);
  } catch (e) {
    if (e.code === 'invalid_login') { saveSession(null); show('login-view'); return; }
    showError(e);
  }
}
// اسم دخول الموظف (بلا @) ← بريده الداخلي (D29)
function loginEmail(v) {
  const t = toLatinDigits(v).trim();
  return t.includes('@') ? t : `staff.${t.toLowerCase()}@wasmmedia.net`;
}
$('login-form').addEventListener('submit', (ev) => {
  ev.preventDefault();
  guarded(async () => {
    saveSession(await authToken('grant_type=password', { email: loginEmail($('login-email').value), password: $('login-password').value }));
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

// ===== المهام (الشريحة 2أ، 2ج) =====
// السيرفر يقرر ما يظهر: الموظف يقرأ مهامه الحالية فقط، والشريك والمدير كل المهام. هنا عرض وأزرار ورسائل.
const TASK_STATUS = { new: 'جديدة', in_progress: 'قيد العمل', ready_for_review: 'جاهزة للمراجعة', done: 'منجزة', cancelled: 'ملغاة' };
const TASK_GROUPS = ['new', 'in_progress', 'ready_for_review'];
const FILE_KIND = { draft: 'مسودة', review: 'مراجعة', final: 'نهائي' };
const FILE_TYPES = new Set(['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'video/mp4', 'application/zip', 'application/x-zip-compressed']);
const MAX_FILE = 52428800; // 50MB (D27)
let tasks = [];
let taskFiles = [];
let returnNotes = {};
let names = {};
let openFiles = new Set(); // المهام التي فُتحت ملفاتها (تبقى مفتوحة بعد التحديث)
let openGroups = new Set(); // «منجزة» و«ملغاة» المفتوحتان
const manages = () => me && (me.role === 'partner' || me.role === 'manager');
const isFinal = (t) => t.status === 'done' || t.status === 'cancelled';
const fmtSize = (b) => (b >= 1048576 ? `${(b / 1048576).toFixed(1)} MB` : `${Math.max(1, Math.round(b / 1024))} KB`);

async function loadTasks() {
  const [t, f, notes, ppl] = await Promise.all([
    api('tasks?select=id,job_number,job_title,title,description,due_date,assignee,status&order=id.asc'),
    api('task_files?select=id,task_id,object_path,file_name,mime,size_bytes,kind,finished_at,approved_at&finished_at=not.is.null&order=id.asc'),
    api('task_log?select=task_id,note&kind=eq.status&from_status=eq.ready_for_review&to_status=eq.in_progress&order=id.asc'),
    manages() ? api('people?select=user_id,display_name') : Promise.resolve([]),
  ]);
  tasks = t; taskFiles = f;
  returnNotes = {}; for (const n of notes) returnNotes[n.task_id] = n.note; // آخر ملاحظة إعادة لكل مهمة
  names = Object.fromEntries(ppl.map((p) => [p.user_id, p.display_name]));
  renderTasks();
}

function renderTasks() {
  const wrap = $('task-groups');
  wrap.replaceChildren();
  const byDue = (a, b) => (a.due_date || '9999').localeCompare(b.due_date || '9999') || a.id - b.id;
  for (const st of TASK_GROUPS) {
    const list = tasks.filter((t) => t.status === st).sort(byDue);
    const body = el('div', { class: 'task-list' }, ...list.map(taskCard));
    if (!list.length) body.append(el('div', { class: 'col-empty', text: '—' }));
    wrap.append(el('section', { class: `task-group group-${st}`, 'data-group': st },
      el('header', { class: 'col-head' }, el('span', { text: TASK_STATUS[st] }), el('span', { class: 'count', text: String(list.length) })),
      body));
  }
  for (const st of ['done', 'cancelled']) {
    const list = tasks.filter((t) => t.status === st).sort((a, b) => b.id - a.id);
    const d = el('details', { class: 'cancelled task-closed', 'data-group': st },
      el('summary', { 'data-testid': `group-${st}` }, el('span', { text: TASK_STATUS[st] }), el('span', { class: 'count', text: String(list.length) })),
      el('div', { class: 'task-list' }, ...(list.length ? list.map(taskCard) : [el('div', { class: 'col-empty', text: 'لا شيء بعد.' })])));
    if (openGroups.has(st)) d.open = true;   // يبقى مفتوحًا بعد التحديث
    d.addEventListener('toggle', () => { if (d.open) openGroups.add(st); else openGroups.delete(st); });
    wrap.append(d);
  }
  $('tasks-open-count').textContent = String(tasks.filter((t) => !isFinal(t)).length);
}

function taskCard(t) {
  const n = t.id;
  const mine = t.assignee === session?.uid;
  const actions = el('div', { class: 'card-actions' });
  const act = (label, testid, cls, fn) => actions.append(el('button', { type: 'button', class: cls, 'data-testid': `${testid}-${n}`, text: label, onclick: () => guarded(fn) }));
  if (mine && t.status === 'new') act('بدء العمل', 'task-start', 'btn-step', () => setStatus(t, 'in_progress'));
  if (mine && t.status === 'in_progress') act('جاهزة للمراجعة', 'task-submit', 'btn-step', () => setStatus(t, 'ready_for_review'));
  if (manages() && t.status === 'ready_for_review' && !(me.role === 'manager' && mine)) {
    act('اعتماد', 'task-approve', 'btn-step', () => setStatus(t, 'done'));
    act('إعادة بملاحظة', 'task-return', 'btn-quiet', () => openReason(t, 'return'));
  }
  if (manages() && !isFinal(t)) {
    act('تعديل', 'task-edit', 'btn-quiet', () => openEditTask(t));
    act('إعادة تكليف', 'task-assign', 'btn-quiet', () => openAssign(t));
    act('إلغاء', 'task-cancel', 'btn-quiet danger', () => openReason(t, 'cancel'));
  }
  act('السجل', 'task-log', 'btn-quiet', () => openTaskLog(t));
  const note = t.status === 'in_progress' ? returnNotes[n] : null;
  return el('article', { class: `card task status-${t.status}`, 'data-testid': `task-${n}` },
    el('div', { class: 'card-top' },
      el('span', { class: 'num', text: `#${t.job_number}` }),
      el('span', { class: `tag st-${t.status}`, 'data-testid': `task-status-${n}`, text: TASK_STATUS[t.status] })),
    el('div', { class: 'client', 'data-testid': `task-title-${n}`, text: t.title }),
    el('div', { class: 'title', text: t.job_title }),
    t.description ? el('div', { class: 'desc', text: t.description }) : null,
    manages() ? el('div', { class: 'due', 'data-testid': `task-assignee-${n}`, text: `المكلَّف: ${names[t.assignee] || '—'}` }) : null,
    t.due_date ? el('div', { class: 'due', text: `الموعد ${fmtDate(t.due_date)}` }) : null,
    note ? el('div', { class: 'return-note', 'data-testid': `task-note-${n}`, text: `ملاحظة المراجعة: ${note}` }) : null,
    actions,
    filesBlock(t));
}

async function setStatus(t, to, note = null) {
  try { await rpc('set_task_status', { p_task: t.id, p_from: t.status, p_to: to, p_note: note }); }
  catch (e) { await loadTasks(); throw e; } // القائمة تتحدّث دائمًا بعد الرفض لتعرض الحالة الحقيقية
  await loadTasks();
}

// ----- مهمة جديدة / تعديل -----
let taskMode = null; // { kind: 'new' } | { kind: 'edit', task }
let assignable = null;
async function loadAssignable() { if (!assignable) assignable = await rpc('assignable_people', {}); return assignable; }
function fillPeople(select, exclude) {
  select.replaceChildren(el('option', { value: '', text: '— اختر —' }),
    ...assignable.filter((p) => p.user_id !== exclude).map((p) => el('option', { value: p.user_id, text: p.display_name })));
}
async function openNewTask() {
  const [jobsOpen] = await Promise.all([
    api('jobs?select=job_number,client,title&stage=not.in.(delivered,cancelled)&order=job_number.desc'), loadAssignable()]);
  taskMode = { kind: 'new' };
  const f = $('task-form'); f.reset(); $('tf-msg').hidden = true;
  $('task-dialog-title').textContent = 'مهمة جديدة';
  $('tf-job-label').hidden = false; $('tf-assignee-label').hidden = false;
  f.elements.job.replaceChildren(el('option', { value: '', text: '— اختر —' }),
    ...jobsOpen.map((j) => el('option', { value: String(j.job_number), text: `#${j.job_number} · ${j.client} · ${j.title}` })));
  fillPeople(f.elements.assignee);
  $('task-dialog').showModal();
}
function openEditTask(t) {
  taskMode = { kind: 'edit', task: t };
  const f = $('task-form'); f.reset(); $('tf-msg').hidden = true;
  $('task-dialog-title').textContent = 'تعديل المهمة';
  $('tf-job-label').hidden = true; $('tf-assignee-label').hidden = true;
  f.elements.title.value = t.title;
  f.elements.due.value = t.due_date ? fmtDate(t.due_date) : '';
  f.elements.desc.value = t.description || '';
  $('task-dialog').showModal();
}
$('task-form').elements.due.addEventListener('input', (ev) => {
  const v = toLatinDigits(ev.target.value); if (v !== ev.target.value) ev.target.value = v;
});
$('task-form').addEventListener('submit', (ev) => {
  ev.preventDefault();
  const f = ev.target.elements;
  const msg = (code) => { $('tf-msg').textContent = ERRORS[code] || ERRORS.network; $('tf-msg').hidden = false; };
  guarded(async () => {
    try {
      const due = parseDue(f.due.value);
      if (taskMode.kind === 'new') {
        if (!f.job.value) throw new AppError('job_required');
        if (!f.assignee.value) throw new AppError('assignee_required');
        await rpc('create_task', { p_job: Number(f.job.value), p_title: f.title.value, p_assignee: f.assignee.value, p_due: due, p_description: f.desc.value || null });
      } else {
        await rpc('edit_task', { p_task: taskMode.task.id, p_title: f.title.value, p_due: due, p_description: f.desc.value || null });
      }
    } catch (e) { msg(e.code); if (['stale_status', 'final_status', 'task_not_found'].includes(e.code)) await loadTasks(); return; }
    $('task-dialog').close();
    await loadTasks();
  });
});

// ----- إعادة تكليف -----
let assignTask = null;
async function openAssign(t) {
  await loadAssignable();
  assignTask = t;
  fillPeople($('assign-select'), t.assignee);
  $('assign-dialog').showModal();
}
$('assign-form').addEventListener('submit', (ev) => {
  ev.preventDefault();
  const who = $('assign-select').value;
  if (!who) return;
  guarded(async () => {
    try { await rpc('assign_task', { p_task: assignTask.id, p_assignee: who }); }
    catch (e) { $('assign-dialog').close(); await loadTasks(); throw e; }
    $('assign-dialog').close();
    await loadTasks();
  });
});

// ----- إلغاء بسبب / إعادة بملاحظة -----
let reasonFor = null; // { task, mode }
function openReason(t, mode) {
  reasonFor = { task: t, mode };
  $('reason-title').textContent = mode === 'cancel' ? 'إلغاء المهمة' : 'إعادة المهمة للعمل';
  $('reason-hint').textContent = mode === 'cancel' ? 'الإلغاء نهائي.' : 'تصل الملاحظة للمكلَّف مع المهمة.';
  $('reason-label-text').textContent = mode === 'cancel' ? 'سبب الإلغاء' : 'الملاحظة';
  $('reason-confirm').className = mode === 'cancel' ? 'btn-danger' : 'btn-primary';
  $('reason-text').value = ''; $('reason-msg').hidden = true;
  $('reason-dialog').showModal();
}
$('reason-form').addEventListener('submit', (ev) => {
  ev.preventDefault();
  const text = $('reason-text').value;
  const { task, mode } = reasonFor;
  if (!/[\p{L}\p{N}]/u.test(text)) { $('reason-msg').textContent = ERRORS[mode === 'cancel' ? 'reason_required' : 'note_required']; $('reason-msg').hidden = false; return; }
  guarded(async () => {
    try {
      if (mode === 'cancel') await rpc('cancel_task', { p_task: task.id, p_from: task.status, p_reason: text });
      else await rpc('set_task_status', { p_task: task.id, p_from: task.status, p_to: 'in_progress', p_note: text });
    } catch (e) { $('reason-dialog').close(); await loadTasks(); throw e; }
    $('reason-dialog').close();
    await loadTasks();
  });
});

// ----- سجل المهمة -----
async function openTaskLog(t) {
  const rows = await api(`task_log?select=kind,from_status,to_status,from_assignee,to_assignee,note,by_name,at&task_id=eq.${t.id}&order=id.asc`);
  const who = (id) => names[id] || '';
  $('task-log-meta').replaceChildren(
    el('div', { class: 'client', text: t.title }), el('div', { class: 'title', text: `#${t.job_number} · ${t.job_title}` }),
    el('div', { class: 'state', text: `الحالة الحالية: ${TASK_STATUS[t.status]}` }));
  const line = (r) => {
    if (r.kind === 'create') return who(r.to_assignee) ? `أُنشئت وكُلِّف بها ${who(r.to_assignee)}` : 'أُنشئت المهمة';
    if (r.kind === 'status') return `${TASK_STATUS[r.from_status]} ← ${TASK_STATUS[r.to_status]}`;
    if (r.kind === 'assign') return who(r.from_assignee) ? `إعادة تكليف: ${who(r.from_assignee)} ← ${who(r.to_assignee)}` : 'إعادة تكليف';
    return 'تعديل التفاصيل';
  };
  $('task-log-list').replaceChildren(...rows.map((r) => el('li', { 'data-testid': 'task-log-row', class: r.to_status === 'cancelled' ? 'is-cancel' : '' },
    el('div', { class: 'move', text: line(r) }),
    el('div', { class: 'by', text: `${r.by_name} · ${fmtStamp(r.at)}` }),
    r.note ? el('div', { class: 'reason', text: r.to_status === 'cancelled' ? `السبب: ${r.note}` : `الملاحظة: ${r.note}` }) : null)));
  $('task-log-dialog').showModal();
}

// ===== الملفات (الشريحة 2ب) =====
// الرفع: حجز مسار من السيرفر ← رفع بهوية المستخدم ← تأكيد. التنزيل بهوية المستخدم مباشرة، بلا أي رابط.
async function storageFetch(path, init = {}) {
  if (session && Date.now() > session.expires_at) await refresh();
  const go = () => fetch(`${BASE}/storage/v1/${path}`, {
    ...init, headers: { apikey: CFG.anonKey || '', authorization: `Bearer ${session?.access_token || ''}`, ...(init.headers || {}) } });
  let r;
  try { r = await go(); } catch { throw new AppError('network'); }
  if ((r.status === 401 || r.status === 403) && session) { await refresh(); try { r = await go(); } catch { throw new AppError('network'); } }
  return r;
}
function filesBlock(t) {
  const n = t.id;
  const list = taskFiles.filter((f) => f.task_id === n);
  const rows = list.map((f) => el('li', { class: 'file', 'data-testid': `file-${f.id}` },
    el('span', { class: 'file-name', text: f.file_name }),
    el('span', { class: 'file-meta', text: `${FILE_KIND[f.kind]} · ${fmtSize(f.size_bytes)} · ${fmtStamp(f.finished_at)}` }),
    f.approved_at ? el('span', { class: 'tag st-done', 'data-testid': `file-approved-${f.id}`, text: 'معتمد' }) : null,
    el('span', { class: 'file-actions' },
      el('button', { type: 'button', class: 'btn-quiet', 'data-testid': `file-dl-${f.id}`, text: 'تنزيل', onclick: () => guarded(() => downloadFile(f)) }),
      manages() && !f.approved_at ? el('button', { type: 'button', class: 'btn-quiet', 'data-testid': `file-approve-${f.id}`, text: 'اعتماد', onclick: () => guarded(() => approveFile(f)) }) : null)));
  const canUpload = !isFinal(t) && (manages() || t.assignee === session?.uid);
  let up = null;
  if (canUpload) {
    const kind = el('select', { 'data-testid': `task-kind-${n}`, 'aria-label': 'نوع الملف' },
      ...Object.entries(FILE_KIND).map(([k, v]) => el('option', { value: k, text: v })));
    const input = el('input', { type: 'file', 'data-testid': `task-upload-${n}`, accept: '.pdf,.jpg,.jpeg,.png,.webp,.mp4,.zip', class: 'file-input' });
    input.addEventListener('change', () => { const file = input.files[0]; input.value = ''; if (file) guarded(() => uploadFile(t, file, kind.value)); });
    up = el('div', { class: 'upload' }, kind, el('label', { class: 'btn-quiet upload-btn' }, el('span', { text: 'رفع ملف' }), input));
  }
  const d = el('details', { class: 'files', 'data-testid': `task-files-${n}` },
    el('summary', { text: `الملفات (${list.length})` }),
    el('ul', { class: 'file-list' }, ...rows), up);
  if (openFiles.has(n)) d.open = true;
  d.addEventListener('toggle', () => { if (d.open) openFiles.add(n); else openFiles.delete(n); });
  return d;
}
async function uploadFile(t, file, kind) {
  openFiles.add(t.id);
  if (!FILE_TYPES.has(file.type)) throw new AppError('file_type');
  if (!file.size) throw new AppError('file_empty');
  if (file.size > MAX_FILE) throw new AppError('file_too_large');
  let slot;
  try { [slot] = await rpc('begin_task_upload', { p_task: t.id, p_name: file.name, p_mime: file.type, p_size: file.size, p_kind: kind }); }
  catch (e) { await loadTasks(); throw e; }
  const r = await storageFetch(`object/task-files/${slot.object_path}`, {
    method: 'POST', body: file, headers: { 'content-type': file.type, 'x-upsert': 'false', 'cache-control': '3600' } });
  if (!r.ok) throw new AppError(r.status === 413 ? 'file_too_large' : r.status === 415 ? 'file_type' : 'upload_failed');
  await rpc('finish_task_upload', { p_file: slot.file_id });
  await loadTasks();
}
async function downloadFile(f) {
  const r = await storageFetch(`object/authenticated/task-files/${f.object_path}`);
  if (!r.ok) { await loadTasks(); throw new AppError('download_failed'); }
  const url = URL.createObjectURL(await r.blob());
  const a = el('a', { href: url, download: f.file_name, hidden: '' });
  document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 30000);
}
async function approveFile(f) {
  try { await rpc('approve_task_file', { p_file: f.id }); } catch (e) { await loadTasks(); throw e; }
  await loadTasks();
}

// ===== رابط الدعوة ← تعيين كلمة السر (P18) =====
// Supabase يعيد المدعو إلى هنا بـ #access_token=…&refresh_token=…&expires_in=…&type=invite (أو type=recovery)،
// أو بـ #error=…&error_code=otp_expired… إن كان الرابط منتهيًا أو مستعملًا. الرمز يُمسح من شريط العنوان فورًا،
// ولا يُخزَّن شيء قبل أن يقبل الخادم كلمة السر.
let invite = null;
{
  const h = new URLSearchParams(location.hash.slice(1));
  if (h.get('error') || h.get('error_code')) invite = { error: true };
  else if (h.get('access_token') && ['invite', 'recovery'].includes(h.get('type'))) {
    invite = { access_token: h.get('access_token'), refresh_token: h.get('refresh_token'), expires_in: Number(h.get('expires_in')) || 3600 };
  }
  if (invite) history.replaceState(null, '', location.pathname + location.search);
}
function setpwMsg(code) { const m = $('setpw-msg'); m.textContent = ERRORS[code]; m.hidden = false; }
$('setpw-form').addEventListener('submit', (ev) => {
  ev.preventDefault();
  const pw = $('setpw-password').value;
  if (pw.length < 8) return setpwMsg('password_short');
  if (pw !== $('setpw-confirm').value) return setpwMsg('password_mismatch');
  $('setpw-msg').hidden = true;
  guarded(async () => {
    let r;
    try {
      r = await fetch(`${BASE}/auth/v1/user`, {
        method: 'PUT',
        headers: { apikey: CFG.anonKey || '', authorization: `Bearer ${invite.access_token}`, 'content-type': 'application/json' },
        body: JSON.stringify({ password: pw }),
      });
    } catch { throw new AppError('network'); }
    if (r.status === 401 || r.status === 403) { invite = null; show('login-view'); throw new AppError('invite_invalid'); }
    if (r.status === 400 || r.status === 422) { setpwMsg('weak_password'); return; }
    if (!r.ok) throw new AppError('network');
    const u = await r.json();
    saveSession({ access_token: invite.access_token, refresh_token: invite.refresh_token, expires_at: Date.now() + (invite.expires_in - 60) * 1000, uid: u.id });
    invite = null;
    $('setpw-password').value = ''; $('setpw-confirm').value = '';
    await enter();
  });
});

// جلسة سابقة على الجهاز لا تُمسح محليًا هنا (مسحها بلا إبطال في الخادم يخالف روح I13)؛ تُستبدل فقط عند نجاح تعيين كلمة السر
if (invite?.access_token) show('setpw-view');
else {
  if (invite?.error) showError(new AppError('invite_invalid'));
  if (session) enter(); else show('login-view');
}
