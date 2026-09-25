reviewed: commit 9929ad5328c6

# مراجعة مستقلة — الـPR wasm-media/wasm-app#1 (الفرع pkg1/bootstrap مقابل main=1ac40db)

- رأس الفرع المراجَع: `9929ad5328c631f1cf23c408d074657c0655ccb0` (تطابق رأس الـPR على GitHub وقت المراجعة).
- قرأت: البروتوكول 1.2.2، INVARIANTS، MISTAKES (حتى N13)، DECISIONS، تعريف الشريحتين 0 و1، ورقة الحزمة P1، وكل ملف في diff الـPR ضمن النطاق.
- عملت على نسخة مستنسخة في `/tmp/rv` (و`/tmp/rv_red` لإعادة الأحمر، ومستودع git مؤقت لطفرات الحارس). لم أعدّل شيئًا في `/home/user/wasm-app`، ولم أعمل commit ولا push، ولم ألمس الإنتاج ولا أي سر.
- ملاحظة بيئة: وجدت خادم اختبار يتيمًا من جلسة المنفّذ (`node /home/user/wasm-app/tests/ui/server.mjs`، PID 14475، بدأ 19:05، أبوه انتهى) يحجز المنفذ 8080. بسببه فشل أول تشغيل لي لاختبار المحاكي (`EADDRINUSE`)، وأول تشغيل حقيقي خدمته نسخة المنفّذ. أوقفته (`kill 14475`) وأعدت كل التشغيلات من قاعدة جديدة. الأرقام أدناه كلها من التشغيلات النظيفة.

---

## 1) الاختبارات: ما شغّلته بنفسي

| الأمر (من جذر `/tmp/rv` على 9929ad5) | المخرج |
|---|---|
| `supabase stop --no-backup` ثم `supabase start -x realtime,storage-api,imgproxy,studio,edge-runtime,logflare,vector` (CLI 2.118.0) | الترحيلات الثلاث طُبّقت على قاعدة جديدة، ومنها `20260925190000_pkg1_partner_seed.sql` |
| `bash tests/ci/run_real.sh` | `sql: WASM_TEST_RESULTS 152 total, 152 ok, FAILED: none` · `opens: 20\|20\|9001\|9020\|9020` · `moves: ok=1 stale=9 state=quote\|1` · `move-vs-cancel: winners=1 log=1` · `PASS concurrency (3 checks)` · `PASS [390x844/ar-PS] 53 checks` · `PASS [1440x900/en-US] 53 checks` · `PASS real` · rc=0 · 106 سطر ok |
| `bash tests/ci/run_mock.sh` (PostgreSQL 16 المحلي + PostgREST 12.2.3) | `PASS [390x844/ar-PS] 45 checks` · `PASS [1440x900/en-US] 45 checks` · `PASS mock` · rc=0 |
| `bash tests/ci/guard_selftest.sh` | 11 من 11 كما يجب، و`PASS guard selftest (11)` |
| `/tmp/actionlint .github/workflows/*.yml` (1.7.7) | لا مخرج، rc=0 |
| تنزيل `postgrest-v12.2.3-linux-static-x64.tar.xz` من GitHub ثم `sha256sum -c` بالقيمة المثبّتة في ci.yml | `OK`: البصمة `9f71269e…527c` صحيحة |

الأعداد تطابق `tests/COUNT`: sql 152، concurrency 3، ui_mock 45 لكل عرض، ui_real 53 لكل عرض.

## 2) الأحمر قبل البناء (CI)

قرأت السجلات بنفسي عبر أدوات GitHub:
- **36176623011 على a5994a2 (اختبارات P18 وحدها): أحمر.** مهمة `supabase-real`: `WASM_TEST_RESULTS 152 total, 147 ok, FAILED: P18 seeded email -> partner + name => 42P01 … | P18 bad fingerprint rejected | P18 blank name rejected | P18 seed trigger fn not callable by app roles | P18 seed table not writable by service_role`.
- **36177168219 على eb061cd (البناء): أخضر.** وكذلك 36178287460 على 9929ad5 (الرأس): المهام الثلاث خضراء.
- 36171181172 على 3aae348: أحمر بسبب `FAIL [390x844/ar-PS] partner sees board`، وهو يطابق N12. و36175000676 على 3dfa324: أخضر.

**حدود هذا الدليل:**
- من فحوص SQL الجديدة الـ11 ظهر 5 فقط أحمر في CI. الستة الباقية نجحت قبل البناء: فحوص الرفض الأربعة تنجح لأن المخطط `private` مغلق أصلًا (42501)، وفحصا «بلا بذرة ← بلا دور» و«تغيير البريد لا يمنح شيئًا» صحيحان حتى بلا trigger. هذا متوقع لفحوص رفض، لكنه يعني أنها لم تُثبت أنها تستطيع الفشل.
- فحوص اللوحة العشرة الجديدة (P18 في `board.spec.mjs`) **لم تُشغَّل أصلًا في CI الأحمر**، لأن `run_real.sh` يتوقف عند فشل SQL. أعدت إنتاجها محليًا: على a5994a2، في نسخة من `run_real.sh` جعلت فيها خطوتي SQL والبذرة غير قاطعتين، خرج `FAIL [390x844/ar-PS] P18 invite link opens the set-password screen, no board yet`. هي إذن ترى شيئًا، لكن احمرارها ليس في CI كما يطلب §2 خطوة 2. هذه مخالفة إجرائية وليست مانعًا (انظر BACKLOG).

## 3) محاولات الكسر: «لا يستطيع» بكل هوية (على المكدّس المحلي الحقيقي)

الهويات حقيقية في GoTrue: شريك (partner1)، وموظف، ومسجّل بلا دور (norole)، وبلا دخول. وزرعت بصمة `target@wasm.test` ولا حساب لها.

| المحاولة | موظف | بلا دور | شريك | بلا دخول |
|---|---|---|---|---|
| تسجيل ذاتي ببريد مزروع `/auth/v1/signup` | — | — | — | 422 `signup_disabled` |
| OTP بـ`create_user:true`، و`/magiclink` | — | — | — | 422 `signup_disabled` |
| تسجيل مجهول `{}`، وتسجيل بالهاتف | — | — | — | 422 `anonymous_provider_disabled` / `signup_disabled` |
| `/auth/v1/invite`، و`admin/generate_link`، و`admin/users` | 403 `not_admin` | 403 | 403 | — |
| قراءة `private.partner_seed` أو كتابتها أو `rpc/seed_partner` عبر REST (`Accept/Content-Profile: private`) | 406 PGRST106 | 406 | 406 | 406 (وكذلك service_role) |
| إدراج/upsert/PATCH على `user_roles`، وإدراج على `people` | 403 42501 | 403 42501 | 403 42501 | — |
| `user_metadata.role=partner` عبر `PUT /auth/v1/user` | يُحفظ لكن لا أثر: القراءة صفر صفوف | نفس الشيء | — | — |
| **تغيير البريد إلى بريد مزروع، مع إكمال التأكيد من Mailpit** | الطلب قُبل (معلّق) | **اكتمل: الحساب صار `target@wasm.test` والدور بقي `-`** | — | — |
| SQL: `set role authenticated` ثم `insert into auth.users`، و`select private.seed_partner()` | 42501 | 42501 | — | — |
| SQL: `set role service_role` ثم `insert into auth.users` أو قراءة البذرة | 42501 | | | |
| قراءة `jobs` | `[]` | `[]` | — | 401 42501 |
| رابط دعوة لبريد غير مزروع ← تعيين كلمة السر من الواجهة (Chromium) | — | اللوحة لا تظهر، وتظهر «لا صلاحية» | — | — |

الامتيازات مقيسة: `service_role` و`authenticated` و`anon` ليس لها INSERT ولا UPDATE ولا DELETE على `user_roles` ولا `people`. ولا أحد منها له USAGE على المخطط `private` (ولا `authenticator` ولا `supabase_auth_admin`). والدالة `seed_partner` SECURITY DEFINER، و`search_path=''`، و`proacl={postgres=X/postgres}`.
**النتيجة:** لم أحصل على دور partner بلا صف بذرة، ولم أقرأ `private.partner_seed` ولم أكتب فيها بأي دور. الطريق الوحيد هو واجهة الإدارة بمفتاح سري، وهذا بالتصميم.

## 4) الواجهة: رابط الدعوة (`web/app.js`، `web/index.html`)

- الرمز يُقرأ من `#…&type=invite|recovery` ثم يُمسح من شريط العنوان فورًا (`history.replaceState`)، ولا يُخزَّن قبل قبول الخادم. لا يُحقن شيء من الـhash في DOM.
- رفض أقل من 8 أحرف، وعدم التطابق، ورسالة الرابط المستعمل: كلها مقيسة في اختبارات P18 الحقيقية (53×2). وجرّبت بيدي دعوة لحساب غير مزروع فانتهت إلى «لا صلاحية».
- لا رجوع: الدخول والخروج (I13) واللوحة كلها خضراء في المحاكي والحقيقي.

## 5) الـworkflows والعمليات

- **ci.yml:** `pull_request` بصلاحية `contents: read` ولا أسرار. CLI مثبّت على 2.118.0. بصمة PostgREST صحيحة (مقيسة). Playwright مثبّت على 1.56.0.
- **guard.yml:** `pull_request_target`. يعمل checkout لـ`base.sha` مع `persist-credentials: false`، ويجلب رأس الـPR كمرجع git فقط، ثم يشغّل `guard.sh` من نسخة main. `guard.sh` لا يستعمل إلا `git diff/log/show`. لم أجد طريقًا لتنفيذ كود من الـPR: `.gitattributes` الخاص بالـPR لا يُقرأ لأن شجرة العمل هي base، ولا textconv ولا filter في الإعداد. **لكن الحارس نفسه يُلتف عليه، انظر المانعين 1 و2.**
- **release.yml:** شرط `if` يقصر `workflow_run` على push من main في المستودع نفسه، ويقصر `workflow_dispatch` على `refs/heads/main`. لكن التشغيل اليدوي من فرع آخر يستعمل نسخة ذلك الفرع من الملف. **الحماية الفعلية هي قاعدة فروع بيئة `production` فقط، وهذه إعدادات لم أستطع قياسها.**
  - المفتاح في `config.js` يمر من `public_key.sh`. جرّبته بـ7 مدخلات: anon JWT مقبول، وsb_publishable مقبول. ورُفضت: JWT دوره service_role حتى وهو تحت الاسم «anon»، وsb_secret في خانة publishable، وقائمة فيها سر وحده، والقائمة الفارغة، والصيغة المجهولة. فلا يصل مفتاح سري إلى `config.js` بهذا المسار. أما `grep 'sb_secret_|service_role'` اللاحق فلا يرى JWT سريًا، لكنه طبقة ثانية فقط.
  - `invites.sh` مجرّب على المكدّس المحلي: لا بريد ولا رابط في stdout (فقط `email #i: …`). يرفض القائمة الفارغة والمفتاح غير الإداري. `RELINK=1` يعطي `type=recovery`.
- **backup.yml:** مقصور على main مع بيئة `backup`. عبارة التشفير تمر عبر fd 3. أما `restore_check.sh` فهو **يستطيع الفشل**، جرّبته على تفريغ حقيقي من المكدّس المحلي (33 جدولًا):
  - نظيف: `PASS restore (33 tables)`، والأعداد تذهب إلى stderr فقط.
  - صف مكرر: `FAIL: restore`.
  - جدول ناقص: `FAIL: table public.jobs missing from the dump`.
  - قيمة غير صالحة: `FAIL`، **مع طباعة القيمة في stdout** (انظر BACKLOG 4).
- **config.toml (N12):** مقيس. التسجيل مرفوض بـ`signup_disabled`، والدخول بكلمة السر يعمل، والتسجيل المجهول مطفأ.
- **CODEOWNERS:** `* @hisabat-isa`.

## 6) الثوابت

| # | الحكم | الدليل |
|---|---|---|
| I1 | لا مساس | لا جداول مالية؛ الموظف يقرأ صفرًا |
| I2 | لا مساس | الشريحة 2 |
| I3 | لا مساس | — |
| I4 | سليم | فحوص I4 (عيّنة مزروعة ثم الحالة الحقيقية) خضراء. الدالة الجديدة definer في `private` لا ينفّذها أي دور تطبيق (مقيس) |
| I5 | سليم | anon: 401 42501 على jobs، و406 على private |
| I6 | سليم | `public_key.sh` يرفض كل مفتاح سري (7 حالات) |
| I7 | سليم | لا جداول قيود |
| I8 | سليم | فحص SQL أخضر |
| I9 | سليم | فحوص السجل والتزامن خضراء |
| **I10** | **غير مفروض بالكامل (مانع 2)** | صف `concurrency 3` في `tests/COUNT` لا يقرؤه أي فحص |
| I11 | سليم في التطوير المحلي | لا SMTP مخصص (Mailpit) |
| **I12** | **غير مفروض آليًا على جلسة المنفّذ (N13)؛ لم يُقس على GitHub** | انظر §7 |
| I13 | سليم | فحوص الخروج خضراء في المحاكي والحقيقي |

## 7) N13: أثره على الأقفال (كما هو)

المقيس الآن (قراءة فقط، بأدوات GitHub):
- `get_me` = `hisabat-isa`، أي هوية الجلسة نفسها هي حساب صاحب المستودع.
- مؤلف الـPR #1 = `hisabat-isa`.
- `list_branches`: main بقيمة `"protected": false`، وحالة الـPR `mergeable_state: clean`.
- على GitHub فرع `probe/p1-write-check` موجود.
- الحارس لم يعمل على هذا الـPR ولا مرة، لأن `guard.yml` غير موجود على main. هذا حتمي في PR الإقلاع.

الأثر:
1. **القفل 2 (لا دمج بلا عيسى): غير موجود الآن.** main غير محمي، وهوية الجلسة تستطيع الدمج. وحتى بعد الحماية: عيسى لا يستطيع Approve على PR مؤلفه هو، و«موافقة CODEOWNERS» لا تتحقق إلا بتجاوز المدير. والجلسة تملك صلاحيات هذا المدير نفسه.
2. **القفل 3 (الحارس):** فحص يستطيع المنفّذ تجاوزه بصلاحية مدير، أو بنشر حالة `guard` عبر API إن لم يُثبَّت مصدر الفحص المطلوب على GitHub Actions. غير مقيس لأن الحماية غير مضبوطة بعد.
3. **I12 والقفل 1:** الأسرار لا تُقرأ نصًا بالـAPI، لكن هوية مالك/مدير تستطيع الكتابة على main أو تغيير قواعد بيئة `production`/`backup`، أو الموافقة على نشر تنتظر موافقة «عيسى» لأنها هو نفسه. فتستطيع تشغيل workflow على main يستعمل أسرار الإنتاج. **I12 إذن غير مفروض آليًا على هذه الجلسة.** لم يُستعمل شيء من ذلك (حسب N13)، ولم أحاول التحقق منه لأنه وصول ممنوع.
4. هذا ليس عيبًا في كود هذا الـcommit، ولا يُصلح داخله. التسجيل الصادق في N13 وP21 صحيح. لكنه **عيب أمني خارج نطاق الإصلاح بالكود، يحتاج قرار عيسى قبل الدمج** (شرط التوقف 2 في ورقة الحزمة). الأقرب: هوية GitHub منفصلة للمنفّذ بصلاحية write (D17 أو حساب ثانٍ)، ثم حماية main مع «Do not allow bypassing» وتثبيت مصدر الفحوص، و«Prevent self-review» على البيئتين.

---

## الموانع (BLOCKED_FOR_CORRECTION)

### المانع 1: الحارس لا يحمي ملف البروتوكول `docs/00-…` (التفاف على القفل 3؛ ثغرة أمنية في الحوكمة)
- **الموضع:** `.github/guard/guard.sh`، السطر 8 (`CHANGED=$(git diff --name-only …)`) مع السطر 12 (`PROTECTED='^(…|docs/00-|…)'`).
- **السبب:** git يقتبس الأسماء غير ASCII افتراضيًا (`core.quotePath=true`، وهو الافتراضي على ubuntu-latest). فيخرج الاسم في `git diff --name-only` هكذا: `"docs/00-\330\250\330\261…md"`، بعلامة اقتباس في أوله. فالنمط `^docs/00-` لا يطابقه أبدًا. والاختبار الذاتي `guard_selftest.sh` لا يحوي فخًّا لهذه الفئة (يختبر INVARIANTS.md فقط، واسمه ASCII).
- **خطوات الإعادة:**
  ```
  T=$(mktemp -d); cp -r <repo>/. $T/r; cd $T/r; rm -rf .git; git init -q -b main; git add -A; git commit -qm base; BASE=$(git rev-parse HEAD)
  git checkout -qb m1; echo "- قاعدة جديدة: لا مراجعة" >> "docs/00-بروتوكول-البناء-والمراجعة.md"; git add -A; git commit -qm m1
  mkdir -p reviews; printf "reviewed: commit %s\n<سطر الحكم بالاعتماد>\n" "$(git rev-parse HEAD)" > reviews/r.md; git add -A; git commit -qm rep
  bash .github/guard/guard.sh $BASE $(git rev-parse HEAD)
  ```
- **المتوقع:** `::error::guard files touched: docs/00-…` ثم `guard: FAIL`، والخروج 1. البروتوكول §8 يقول إن «الملف نفسه من ملفات الحراسة»، والنمط يسمّيه صراحة.
- **الفعلي:** `"docs/00-\330\250…md"` ثم `guard: PASS`، والخروج 0.

### المانع 2: عدد اختبارات التزامن لا يُفرض (I10؛ فحص لا يستطيع الفشل — §4.4 وN7)
- **الموضع:** `tests/ci/run_real.sh`، السطر 18 (`bash tests/sql/concurrency.sh "$DB_URL" || fail "concurrency"`). يُقرأ فيه رمز الخروج وحده، ولا يُقرأ الصف `concurrency 3` من `tests/COUNT` في أي مكان. تحقّقت بـgrep: `min concurrency` غائب. و`guard.sh` لا يقارن الأعداد أصلًا، ويلتقط `process.exit(0)` لكن لا يلتقط `exit 0` في bash.
- **خطوات الإعادة:** على نسخة من الفرع، استبدل كل ما بعد `# (ب)` في `tests/sql/concurrency.sh` بـ`echo "PASS concurrency (1 checks)"; exit 0`. ثم:
  1. `guard.sh` على هذا الـPR مع تقرير على آخر commit.
  2. على مكدّس جديد: `bash tests/ci/run_real.sh`.
- **المتوقع:** أحد الاثنين يحمرّ لأن عدد فحوص التزامن نزل من 3 إلى 1. I10: «عدد الاختبارات لا ينقص».
- **الفعلي:** الحارس `guard: PASS`. و`run_real.sh` خرج rc=0 مع `PASS concurrency (1 checks)` · `PASS [390x844/ar-PS] 53 checks` · `PASS [1440x900/en-US] 53 checks` · `PASS real`. السجل في `/tmp/review/m2_run_real.log`.
- **من الفئة نفسها، للإصلاح معًا:** مشغّل المحاكي `tests/ui/run_ui.sh` ليس ضمن ملفات الحراسة، و`run_mock.sh` المحمي يثق بعدد يطبعه هو. استبدلته بسطرين `PASS [x] 45 checks` مع `exit 0`، فخرج الحارس `guard: PASS`، ومنطق `run_mock.sh` يقبله. تعريف 0أ بند 2.6 يعدّ «إعدادات مشغّل الاختبارات» من ملفات الحراسة.

---

## BACKLOG (لا توقف بها)

1. **مهم قبل الدمج، ولا يوقف بحكم البروتوكول لأنه ليس ثابتًا ولا رجوعًا ولا أمنًا:** لا يوجد ترحيل يزرع بصمتي عيسى وأحمد. رسالة الـcommit تقول «صفوف البصمات بترحيل مستقل»، وهو غير موجود في الـPR. في الإنتاج سيكون `private.partner_seed` فارغًا، و`release.yml` سيولّد دعوتين تنشئان حسابين **بلا دور**. والـtrigger يعمل عند الإنشاء فقط، و`invites.sh` لا يعيد الدعوة لحساب موجود. فلا يصير الشريكان شريكين إلا بترحيل يمنح أدوارًا لحسابات قائمة، أو بـSQL يدوي (ممنوع §5.2). أعدت إنتاج ذلك محليًا: `unseeded@wasm.test` ← invite ← حساب بدور `-`، ثم التشغيل الثاني يطبع «account exists — no link». يجب أن يسبق ترحيل البصمات أول تشغيل لـrelease، أو أن يرفض `invites.sh` أي بريد بلا بصمة.
2. الاحمرار في CI لم يشمل فحوص اللوحة العشرة الجديدة، و6 من 11 فحص SQL لم تحمرّ (§2 أعلاه).
3. `backup.yml`: رفع النسخة يأتي بعد الاستعادة التجريبية. فإن فشلت الاستعادة (مثلًا لاختلاف إصدار مخطط `auth` بين GoTrue المستضاف وCLI 2.118.0) فشلت المهمة ولم تُحفظ نسخة ذلك اليوم. الأفضل رفع الملف المشفّر أولًا أو دائمًا.
4. `restore_check.sh`: في مسار الفشل يطبع إلى stdout، أي السجل العام، حتى 160 حرفًا من سطر `ERROR`. وPostgreSQL يضع القيمة في بعض الأخطاء. مقيس: `ERROR: invalid input syntax for type uuid: "SECRET-CLIENT-NAME-0599123456"`. احتمال حدوثه ضيق (يحتاج انحراف أنواع)، لكنه يخالف وعد D25 «السجل العام لا يطبع أي صف».
5. النسخ يستعمل `SUPABASE_DB_PASSWORD` (مستخدم postgres) و`SUPABASE_ACCESS_TOKEN` (صلاحية الحساب كله) في بيئة بلا موافقة، لا «دور قاعدة بيانات للقراءة فقط» كما في §5.5 وقبول 0ب 3.2.
6. شرط تقرير المراجع في `guard.sh` يطابق عبارة الحكم بالاعتماد في أي موضع من الملف، لا في السطر الأخير. تقرير BLOCKED يقتبس هذه العبارة يمرّ. وفحص الأسرار لا يلتقط JWT من نوع service_role.
7. ملفات حاكمة أخرى غير محمية: `docs/DECISIONS.md` (يمكن قلب عمود «اعتمده عيسى»)، و`docs/MISTAKES.md`، و`docs/slices/`، و`docs/packages/`. البند 2.6 من 0أ يقول «الملفات الحاكمة — فئة بفئة». يحتاج قرار عيسى في أيها محمي.
8. رابط مصنوع `#access_token=<رمز حساب آخر>&type=recovery` يجعل الضحية تضع كلمة سر لحساب المهاجم (تثبيت جلسة). خطره منخفض لأن التسجيل مغلق. وجلسة سابقة على الجهاز تُستبدل دون إبطال في الخادم.
9. مستخدم بدور يستطيع تغيير بريده إلى بريد مزروع لم يُدعَ بعد، إن كان يملك صندوقه. لا يأخذ دورًا (مقيس)، لكنه يحجز البريد فيتخطاه `invites.sh`.
10. الـactions مثبّتة بالوسم لا بالـSHA (`supabase/setup-cli@v1`، `actions/*@v4`، `deploy-pages@v4`).
11. `release.yml` لم يعمل ولا مرة. نشر Pages من بيئة اسمها `production` لا `github-pages` لم يُجرَّب.
12. وصف الـPR #1 قديم: لا يذكر release وbackup وP18.
13. الفرع `probe/p1-write-check` باقٍ على GitHub.
14. الخادم اليتيم على 8080 من جلسة المنفّذ (أوقفته). يُفسد تشغيل الاختبارات اللاحقة بصمت.
15. بصمة sha256 لبريد معروف قابلة للتخمين. إن نُشرت في ترحيل عام فهي لا تخفي البريد عمّن يعرفه.

## ما لم أستطع قياسه

إعدادات GitHub: قواعد فروع البيئتين `production` و`backup`، وهل الأسرار في البيئة أم على مستوى المستودع، ومصدر الفحص المطلوب. وكذلك I12 بفرع تجريبي، وقبول 0أ (1.x، 3.1) كله. main غير محمي الآن، ولم أحاول الوصول إلى أي سر.

الحكم: BLOCKED_FOR_CORRECTION
