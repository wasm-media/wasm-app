// خادم اختبار محلي للّوحة (1ب): يخدم ملفات web/، ويمرّر /rest/v1 إلى PostgREST المحلي،
// ويحاكي نقطتي Supabase Auth اللتين تستعملهما الواجهة (/auth/v1/token بكلمة سر أو refresh_token).
// الهويات حقيقية في auth.users بالقاعدة المحلية؛ الـJWT موقَّع بسرّ PostgREST نفسه، كما تفعل Supabase.
// للاختبار فقط — لا يُنشر.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const ROOT = path.resolve(process.env.WEB_ROOT);
const PORT = Number(process.env.PORT || 8080);
const PGRST = process.env.PGRST || 'http://127.0.0.1:3001';
const SECRET = process.env.JWT_SECRET;
const USERS = JSON.parse(process.env.TEST_USERS || '{}'); // { email: { id, password } }
const REAL = process.env.REAL === '1';                 // وضع حقيقي: خادم ملفات فقط؛ الواجهة تتصل بـSupabase مباشرة
const PGRST_APIKEY = process.env.PGRST_APIKEY || '';   // لبوابة Supabase المحلية (Kong) إن مُرّر /rest/v1 إليها
const REFRESH = new Map(); // refresh_token → email
let failLogout = false;
let TTL = 3600;             // مفتاح اختبار: /__test/ttl?s=N يقصّر عمر رموز الدخول الجديدة    // مفتاح اختبار: /__test/fail-logout يجعل الخروج يرجع 500

const b64u = (b) => Buffer.from(b).toString('base64url');
function sign(uid, email) {
  const now = Math.floor(Date.now() / 1000);
  const head = b64u(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = b64u(JSON.stringify({ sub: uid, email, role: 'authenticated', aud: 'authenticated', iat: now, exp: now + TTL,
    user_metadata: { role: 'partner' }, app_metadata: { role: 'partner' } })); // هجوم ثابت: يجب أن يُتجاهل
  const sig = crypto.createHmac('sha256', SECRET).update(`${head}.${body}`).digest('base64url');
  return `${head}.${body}.${sig}`;
}
function verify(tok) { // توقيع HS256 صحيح + غير منتهٍ، وإلا null
  const [h, b, sig] = (tok || '').split('.');
  if (!h || !b || !sig) return null;
  const good = crypto.createHmac('sha256', SECRET).update(`${h}.${b}`).digest('base64url');
  if (good.length !== sig.length || !crypto.timingSafeEqual(Buffer.from(good), Buffer.from(sig))) return null;
  const c = JSON.parse(Buffer.from(b, 'base64url').toString());
  return c.exp && c.exp > Math.floor(Date.now() / 1000) ? c : null;
}
const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.woff2': 'font/woff2', '.svg': 'image/svg+xml', '.json': 'application/json' };

function readBody(req) { return new Promise((r) => { let d = ''; req.on('data', (c) => (d += c)); req.on('end', () => r(d)); }); }

http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  if (url.pathname === '/config.js' && process.env.CONFIG_URL) { // إعداد الاتصال للوضع الحقيقي (المفتاح العام فقط)
    res.writeHead(200, { 'content-type': 'text/javascript; charset=utf-8' });
    return res.end(`window.WASM_CONFIG = ${JSON.stringify({ url: process.env.CONFIG_URL, anonKey: process.env.CONFIG_ANON || '' })};`);
  }
  if (REAL) { /* لا محاكاة ولا تمرير في الوضع الحقيقي */ }
  else if (url.pathname === '/auth/v1/token' && req.method === 'POST') {
    const body = JSON.parse((await readBody(req)) || '{}');
    let email, u;
    if (url.searchParams.get('grant_type') === 'password') {
      email = body.email; u = USERS[email];
      if (!u || u.password !== body.password) {
        res.writeHead(400, { 'content-type': 'application/json' });
        return res.end(JSON.stringify({ error: 'invalid_grant', error_description: 'Invalid login credentials' }));
      }
    } else if (url.searchParams.get('grant_type') === 'refresh_token') {
      email = REFRESH.get(body.refresh_token); u = USERS[email];
      if (!u) { res.writeHead(400, { 'content-type': 'application/json' }); return res.end('{"error":"invalid_grant"}'); }
      REFRESH.delete(body.refresh_token); // تدوير: الرمز القديم يموت عند استعماله
    }
    const rt = crypto.randomBytes(16).toString('hex'); REFRESH.set(rt, email);
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ access_token: sign(u.id, email), token_type: 'bearer', expires_in: TTL,
      refresh_token: rt, user: { id: u.id, email } }));
  }
  else if (url.pathname === '/__test/live-refresh') { // عدد رموز التجديد الحية لهذا البريد (للاختبار فقط)
    const n = [...REFRESH.values()].filter((e) => e === url.searchParams.get('email')).length;
    res.writeHead(200, { 'content-type': 'application/json' }); return res.end(String(n));
  }
  else if (url.pathname === '/__test/ttl') { TTL = Number(url.searchParams.get('s')) || 3600; res.writeHead(204); return res.end(); }
  else if (url.pathname === '/__test/fail-logout') { failLogout = url.searchParams.get('on') === '1'; res.writeHead(204); return res.end(); }
  else if (url.pathname === '/auth/v1/logout' && req.method === 'POST') {
    // مثل GoTrue: requireAuthentication يفحص التوقيع والانتهاء قبل أي إبطال — الرمز المنتهي ← 403 bad_jwt ولا يُبطَل شيء
    if (failLogout) { res.writeHead(500); return res.end('{}'); }
    const tok = (req.headers.authorization || '').replace(/^Bearer /, '');
    const claims = verify(tok);
    if (!claims) { res.writeHead(403, { 'content-type': 'application/json' }); return res.end('{"code":403,"error_code":"bad_jwt"}'); }
    const sub = claims.sub;
    const email = Object.keys(USERS).find((e) => USERS[e].id === sub);
    for (const [k, v] of REFRESH) if (v === email) REFRESH.delete(k);
    res.writeHead(204); return res.end();
  }
  else if (url.pathname.startsWith('/rest/v1/')) {
    const target = PGRST + url.pathname.slice('/rest/v1'.length) + url.search;
    const headers = { ...req.headers }; delete headers.host; delete headers.apikey;
    if (PGRST_APIKEY) headers.apikey = PGRST_APIKEY;
    const r = await fetch(target, { method: req.method, headers, body: ['GET', 'HEAD'].includes(req.method) ? undefined : await readBody(req) });
    const buf = Buffer.from(await r.arrayBuffer());
    res.writeHead(r.status, { 'content-type': r.headers.get('content-type') || 'application/json' });
    return res.end(buf);
  }
  let p = path.join(ROOT, decodeURIComponent(url.pathname === '/' ? '/index.html' : url.pathname));
  if (!p.startsWith(ROOT) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { res.writeHead(404); return res.end('not found'); }
  res.writeHead(200, { 'content-type': types[path.extname(p)] || 'application/octet-stream' });
  fs.createReadStream(p).pipe(res);
}).listen(PORT, () => console.log(`ui test server on ${PORT}`));
