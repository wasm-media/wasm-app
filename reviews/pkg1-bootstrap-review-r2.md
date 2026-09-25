reviewed: commit 9bcb70abca6f

# مراجعة مستقلة، الجولة 2 من 2: الـPR wasm-media/wasm-app#1 (الفرع pkg1/bootstrap)

- الـcommit المراجَع: `9bcb70abca6f654a7732b2ec9696177b08f674ee`. وهو رأس الـPR على GitHub وقت المراجعة (`pull_request_read`: `head.sha` نفسه، و`base` = `1ac40db`).
- نطاق الجولة 2 (§3.2): أسباب رفض الجولة 1، والرجوع، والثوابت، والأمن. الفرق المفحوص هو `git diff 9929ad5328c6 9bcb70abca6f` (7 ملفات).
- بيئة العمل: نسخة نظيفة من الـcommit عبر `git archive` في `/tmp/rv2`، وطفرات في `/tmp/rvm` ومستودعات git مؤقتة. لم أعدّل شيئًا في `/home/user/wasm-app` (شجرة العمل نظيفة والرأس `9bcb70a`). لم أعمل commit ولا push، ولم ألمس الإنتاج ولا أي سر.
- `/tmp/wr` مطابق للـcommit ملفًا ملفًا (قارنته بـ`cmp` على كل ملف في `git ls-files -z`). مع ذلك أوقفت المكدّس وأعدت تشغيله من `/tmp/rv2`.
- المنفذ 8080 كان فارغًا قبل كل تشغيل للّوحة، ولم يبقَ بعدها أي خادم يتيم.

---

## 1) الاختبارات: ما شغّلته بنفسي

| الأمر (من جذر `/tmp/rv2` على 9bcb70a) | المخرج |
|---|---|
| `supabase stop --no-backup` ثم `supabase start -x realtime,storage-api,imgproxy,studio,edge-runtime,logflare,vector` (CLI 2.118.0) | طُبّقت الترحيلات الثلاث على قاعدة جديدة |
| `bash tests/ci/run_real.sh` | `sql: WASM_TEST_RESULTS 152 total, 152 ok, FAILED: none` · `opens: 20\|20\|9001\|9020\|9020` · `moves: ok=1 stale=9 state=quote\|1` · `move-vs-cancel: winners=1 log=1` · `PASS concurrency (3 checks)` · `PASS [390x844/ar-PS] 53 checks` · `PASS [1440x900/en-US] 53 checks` · `PASS real`، ورمز الخروج 0، و106 أسطر ok. السجل في `/tmp/review/r2_run_real.log` |
| `bash tests/ci/run_mock.sh` | `PASS [390x844/ar-PS] 45 checks` · `PASS [1440x900/en-US] 45 checks` · `PASS mock`، ورمز الخروج 0. السجل في `r2_run_mock.log` |
| `bash tests/ci/guard_selftest.sh` | 14 من 14 كما يجب، ثم `PASS guard selftest (14)`. السجل في `r2_guard_selftest.log` |
| `/tmp/actionlint .github/workflows/*.yml` | لا مخرج، ورمز الخروج 0 |

الأعداد تطابق `tests/COUNT`: sql 152، concurrency 3، ui_mock 45، ui_real 53.

**CI على GitHub** (قرأت السجلات بنفسي): التشغيل 36181588910 على 9bcb70a أخضر في مهامه الثلاث: `guard-selftest` (يظهر فيه `PASS guard selftest (14)` مع الفخاخ الثلاثة الجديدة، وgit 2.55.0)، و`ui-mock`، و`supabase-real` (يظهر فيه `PASS [1440x900/en-US] 53 checks` ثم `PASS real`).

## 2) هل أُصلح مانعا الجولة 1؟ أعدت خطوات إعادتهما حرفيًا

### المانع 1 (الحارس لا يرى `docs/00-…` بسبب core.quotePath): **أُصلح في صورته المبلَّغ عنها**
- أعدت خطوات الجولة 1 حرفيًا: أضفت سطرًا إلى `docs/00-بروتوكول-البناء-والمراجعة.md`، وأرفقت تقريرًا «معتمد» على آخر commit، ثم شغّلت `guard.sh`. الناتج `::error::guard files touched: docs/00-بروتوكول-البناء-والمراجعة.md` ثم `guard: FAIL`، ورمز الخروج 1.
- وأعدتها مع `git config core.quotePath true` صريحًا في المستودع، كما هو الافتراضي على الـrunner: FAIL، ورمز الخروج 1.
- **لكن الصنف نفسه لم يُغلق.** الحارس ما زال يعتمد على نص `git diff --name-only`، فيفوته كل مسار محمي لا يظهر في هذا النص كما هو. انظر المانع أدناه.

### المانع 2 (عدد التزامن غير مفروض، و`run_ui.sh` غير محمي): **أُصلح**
- طفرة الجولة 1 حرفيًا: استبدلت ما بعد `# (ب)` في `tests/sql/concurrency.sh` بـ`echo "PASS concurrency (1 checks)"; exit 0`، ثم شغّلت `supabase db reset` ثم `bash tests/ci/run_real.sh`. الناتج `PASS concurrency (1 checks)` ثم `FAIL: concurrency count 1 < 3`، ورمز الخروج 1. السجل في `/tmp/review/r2_m2_run_real.log`.
  الحارس ما زال يمرّر هذه الطفرة، وهذا مقبول: المطلوب أن يحمرّ أحد الاثنين، وقد احمرّ `run_real.sh`.
- استبدلت `tests/ui/run_ui.sh` بسطرين `PASS [x] 45 checks` ثم `exit 0`، مع تقرير «معتمد». الناتج `::error::guard files touched: tests/ui/run_ui.sh` ثم `guard: FAIL`، ورمز الخروج 1.

### الأحمر قبل الإصلاح
- لا يوجد تشغيل CI أحمر للفخاخ الجديدة، لأنها أُضيفت في الـcommit نفسه الذي يصلح الحارس.
- أعدت إنتاج الأحمر محليًا: شغّلت `guard_selftest.sh` الجديد مع `guard.sh` من 9929ad5، فظهرت الفخاخ الثلاثة الجديدة كلها `BAD … → PASS (want FAIL)` ثم `FAIL guard selftest`، ورمز الخروج 1.
- وفحص عدد التزامن أثبتُّ أنه يستطيع الفشل بالطفرة أعلاه (انظر BACKLOG 5).

## 3) الرجوع

لا رجوع. كل ما سبق أخضر: 152 SQL، و3 تزامن، و53×2 حقيقي، و45×2 محاكي، و14 من 14 للحارس.

فحصت بيدي على المكدّس الحقيقي بهويات حقيقية من GoTrue: موظف `emp2`، وشريك `part2`، وبلا دخول:

| المحاولة | بلا دخول | موظف | شريك |
|---|---|---|---|
| قراءة `jobs` | 401 42501 | 200 `[]` | 200 (بيانات) |
| إدراج في `user_roles` | 401 42501 | 403 42501 | 403 42501 |
| قراءة `private.partner_seed` | 406 PGRST106 | 406 | 406 |
| `rpc/create_job` | 401 42501 | 400 `not_partner` | 200 (9021) |
| `rpc/move_job` و`rpc/cancel_job` | 401 42501 | 400 `not_partner` | 200 |
| `DELETE jobs` | 401 | 403 42501 | 403 42501 |
| `/auth/v1/signup` | 422 `signup_disabled` | — | — |

## 4) الأمن في التغييرات الجديدة

- **`guard.sh`، شرط «آخر سطر»:** يطابق أول سطر بـ`^reviewed: (commit )?<LAST:12>`، ويشترط أن يكون آخر سطر غير فارغ هو `الحكم: معتمد` حرفيًا.
  - تقرير BLOCKED يقتبس عبارة الاعتماد يُرفض (الفخ t13).
  - أسماء التقارير تُقرأ سطرًا سطرًا، فلا تنكسر بالمسافات.
  - اسم تقرير مقتبس أو محذوف يسقط إلى «لا تقرير»، وهذا اتجاه آمن.
  - لم أجد تمريرًا خاطئًا.
- **`invites.sh`** (جرّبته على المكدّس المحلي):
  - بريدان بلا بصمة في `supabase/migrations`: يطبع `FAIL: email #1 has no seed fingerprint …`، ورمز الخروج 1، ولا حساب يُنشأ (عدد المستخدمين 0 قبل وبعد)، ولا ملف `.count`.
  - الأول مبصوم والثاني لا: يرفض قبل أي رابط، و0 حسابات.
  - بريد مبصوم بحروف كبيرة: `invite link written`، والحساب صار `partner|ألفا` بالـtrigger. لا بريد ولا رمز في stdout.
  - التشغيل الثاني يطبع `account exists — no link`، و`RELINK=1` يعطي `type=recovery`.
  - القائمة الفارغة، والمفتاح غير الإداري (403)، ومجلد ترحيلات غير موجود: كلها ترفض برمز خروج 1.
  - التطبيع (`tr` ثم lower) يطابق `lower(btrim(email))` في الـtrigger.
- **`restore_check.sh`:** جرّبته على تفريغ حقيقي من المكدّس (33 جدولًا).
  - النسخة النظيفة: `PASS restore (33 tables)`، ولا عدد في stdout.
  - قيمة مزروعة `SECRET-CLIENT-NAME-0599123456` في عمود uuid، مع `QUIET=1`: stdout = `FAIL: restore` فقط، والقيمة 0 مرة في stdout ومرة في stderr. وبلا QUIET تظهر محليًا كما هو موثّق.
  - صف مكرر: `FAIL: restore`، ورمز الخروج 1.
  - جدول ناقص: `FAIL: table public.jobs missing from the dump`.
  - فالفحص ما زال يستطيع الفشل.
- **`backup.yml`:** شغّلت نص الخطوتين 3 و4 (مستخرَجًا من الـYAML) محليًا، مع مستودع bare بدل GitHub (`REMOTE`)، ونسخ مشفّرة حقيقية.
  - الخطوة 3 ترفع النسخ الثلاث أولًا (`pushed … (3 files)`).
  - الخطوة 4 مع نسخة سليمة: `PASS restore`، ثم رفع التقرير المشفّر، ورمز الخروج 0.
  - الخطوة 4 مع نسخة فيها قيمة فاسدة: السجل فيه `FAIL: restore` فقط، والقيمة السرية 0 مرة فيه. رُفع تقرير مشفّر فيه `rc=1` وسطر الخطأ، وخرجت الخطوة برمز 1.
  - `D` ينتقل عبر `GITHUB_ENV`.
  - ملاحظة غير مانعة في BACKLOG 2.
- **`ci.yml`:** تغيّر اسم الخطوة فقط.

## 5) الثوابت

| # | الحكم | الدليل |
|---|---|---|
| I1 | لا مساس | الموظف يقرأ `[]` |
| I2، I3، I7 | لا مساس | خارج الفرق |
| I4 | سليم | فحوص I4 ضمن الـ152 خضراء |
| I5 | سليم | بلا دخول: 401 على jobs، و406 على private |
| I6 | لا مساس | `public_key.sh` لم يتغيّر |
| I8 | سليم | DELETE مرفوض (403/401)، وفحص SQL أخضر |
| I9 | سليم | فحوص السجل والتزامن خضراء |
| **I10** | **العدّ مفروض الآن للأربعة** (sql، concurrency، ui_mock، ui_real)، ومشغّل المحاكي محمي | لكن ملف العدّ `tests/COUNT` نفسه يمكن نقله دون أن يلتقطه الحارس. يحمرّ CI عندها لأن `min` يعيد فراغًا، فالعدّ لا ينكسر بهذا الطريق. الأخطر نقل ملفات الحراسة الأخرى (المانع أدناه) |
| I11 | لا مساس | — |
| I12 | **غير مفروض آليًا على جلسة المنفّذ (N13)**، كما في الجولة 1 | قرار عيسى قبل الدمج، وغير مقيس هنا |
| I13 | سليم | فحوص الخروج خضراء في المحاكي والحقيقي |

---

## المانع (BLOCKED_FOR_CORRECTION)

### المانع 1 (الجولة 2): الحارس ما زال لا يرى ملفات الحراسة التي لا يطبعها `git diff --name-only` بمسارها المحمي. إصلاح المانع 1 من الجولة 1 أغلق حالة واحدة من الصنف
هذا التفاف على القفل 3، وعلى قبول 0أ بند 2.6: «يلمس ملفات الحراسة … فئة بفئة». أي أنه ثغرة أمنية في الحوكمة.

- **الموضع:** `.github/guard/guard.sh`، السطر 10 (`CHANGED=$(g diff --name-only "$BASE...$HEAD")`) مع السطرين 15 و16 (`PROTECTED=…`، `grep -E`).
- **السبب:** `core.quotePath=false` يُلغي اقتباس الأحرف غير ASCII فقط، وبقي سببان يخفيان المسار المحمي:
  1. **كشف إعادة التسمية** (`diff.renames=true`، وهو الافتراضي في git منذ 2.18، والـrunner عليه git 2.55.0). ملف محمي يُنقل أو يُنقل ويُعدَّل يظهر باسمه الجديد وحده، فلا يطابقه النمط.
  2. **git ما زال يقتبس** الأسماء التي فيها `"` أو `\` أو محارف تحكم (tab، سطر جديد) حتى مع `quotePath=false`. فملف جديد تحت `.github/` أو `tests/ci/` يظهر هكذا: `".github/workflows/de\"ploy.yml"`، ولا يطابقه `^\.github/`.
- **خطوات الإعادة** (كلها على نسخة من 9bcb70a):
  ```
  T=$(mktemp -d); cp -r /tmp/rv2/. $T/r; cd $T/r; rm -rf .git; git init -q -b main
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
  git add -A; git commit -qm base; BASE=$(git rev-parse HEAD)
  rep(){ mkdir -p reviews; printf "reviewed: commit %s\nالحكم: معتمد\n" "$(git rev-parse HEAD)" > reviews/r.md; git add -A; git commit -qm rep; }
  # (أ) نقل البروتوكول وتعديل قاعدة فيه
  git checkout -qb a; git mv "docs/00-بروتوكول-البناء-والمراجعة.md" docs/protocol.md
  sed -i 's/جولتا مراجعة كحد أقصى لكل شريحة/جولة مراجعة واحدة تكفي/' docs/protocol.md; git add -A; git commit -qm a; rep
  bash .github/guard/guard.sh $BASE $(git rev-parse HEAD); echo rc=$?; git checkout -q main
  # (ب) نقل CODEOWNERS إلى الجذر وإضافة مالك
  git checkout -qb b; git mv .github/CODEOWNERS CODEOWNERS; echo "/web/ @someone-else" >> CODEOWNERS; git add -A; git commit -qm b; rep
  bash .github/guard/guard.sh $BASE $(git rev-parse HEAD); echo rc=$?; git checkout -q main
  # (ج) workflow جديد في اسمه علامة اقتباس
  git checkout -qb c; printf 'name: x\non: push\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n' > '.github/workflows/de"ploy.yml'
  git add -A; git commit -qm c; rep; bash .github/guard/guard.sh $BASE $(git rev-parse HEAD); echo rc=$?
  ```
- **المتوقع:** في الحالات الثلاث `::error::guard files touched: …` ثم `guard: FAIL`، ورمز الخروج 1. كلها تمسّ ملفات حراسة: البروتوكول، وCODEOWNERS، و`.github/`.
- **الفعلي:**
  - (أ) `docs/protocol.md reviews/r.md guard: PASS`، ورمز الخروج 0.
  - (ب) `CODEOWNERS reviews/r.md guard: PASS`، ورمز الخروج 0. وGitHub يقرأ `CODEOWNERS` من الجذر إن غاب من `.github/`.
  - (ج) `".github/workflows/de\"ploy.yml" reviews/r.md guard: PASS`، ورمز الخروج 0.
  - وكذلك مرّ: نقل `docs/INVARIANTS.md` إلى `docs/INVARIANTS-v2.md` مع قلب «يوقف» إلى «لا يوقف»، واسم بشرطة مائلة عكسية `.github/workflows/de\ploy.yml`، وملف `tests/ci/a<TAB>b.sh`.
- **ملاحظات:**
  - الثغرة موجودة أيضًا في 9929ad5 (جرّبت نقل INVARIANTS على الحارس القديم فخرج PASS)، فليست رجوعًا. لكنها الصنف نفسه الذي رُفضت به الجولة 1: الحارس لا يرى المسار كما هو.
  - لم أقِس هل يشغّل GitHub فعلًا workflow في اسمه `"`. يحتاج دفعًا، وهو ممنوع عليّ. لكن حالتي (أ) و(ب) لا تعتمدان على ذلك.
  - للعلم فقط دون إصلاح: `git diff --no-renames` يُظهر المسار القديم (جرّبته). والقراءة بـ`-z` لا تقتبس أي اسم.
  - الفخاخ في `guard_selftest.sh` لا تغطي النقل ولا هذه الأسماء.

---

## BACKLOG (لا توقف بها)

1. **العدّ يطبعه ملف اختبار غير محمي.** `concurrency.sh` المعدَّل إلى `echo "PASS concurrency (3 checks)"; exit 0` يمرّ من الحارس (`guard: PASS`) ومن `run_real.sh` (يصل إلى خطوة اللوحة). وهذا ينطبق كذلك على `slice1a_test.sql` و`board.spec.mjs`. هذا بنيوي، والمراجع هو الدفاع. والحارس لا يلتقط `exit 0` في bash.
2. **`backup.yml`، الخطوة 4:** بلا `-e`، ويُتجاهل رمز خروج `push_private.sh` للتقرير. جرّبته: استعادة سليمة ثم فشل رفع التقرير (مستودع غير موجود) أعطى `FAIL: clone private repo` ورمز الخروج 0، فالمهمة خضراء بلا تقرير استعادة. النسخ نفسها محفوظة لأن الخطوة 3 بـ`-e`. والحال نفسه إن فشل تشفير التقرير.
3. **`backup.yml`:** `BACKUP_DEPLOY_KEY` صار في بيئة خطوة الاستعادة كلها (`supabase start` وpsql على بيانات الإنتاج). توسيع طفيف لظهور المفتاح، والأفضل رفع التقرير في خطوة منفصلة.
4. **`invites.sh`:**
   - يبحث عن البصمة نصًا في أي ملف ترحيل، بما فيه تعليق أو ترحيل يحذف الصف، لا في القاعدة. قد ينتج إيجابيًا كاذبًا.
   - أول `release` بعد الدمج سيحمرّ في خطوته الأخيرة حتى يُدمج ترحيل البصمتين. هذا مقصود، لكن يجب ذكره لعيسى.
   - بقية BACKLOG 1 من الجولة 1 (ترحيل بصمتي عيسى وأحمد غير موجود) ما زالت قائمة، وهي في «ما يبقى قبل الدمج» في وصف الـPR.
5. **لا تشغيل CI أحمر** للفخاخ الثلاثة الجديدة ولا لفرض عدد التزامن. أثبتُّ احمرارها محليًا (§2). مخالفة إجرائية لـ§2 خطوة 2.
6. **فحص الأسرار في الحارس** ما زال لا يلتقط JWT من نوع service_role (من BACKLOG 6 في الجولة 1، ولم يتغيّر).
7. بقية بنود BACKLOG من الجولة 1 التي لم يمسّها هذا الفرق ما زالت كما هي: 2، 5، 7 إلى 15. منها أن `docs/DECISIONS.md` و`docs/MISTAKES.md` غير محميين، والـactions مثبّتة بالوسم لا بالـSHA، والفرع `probe/p1-write-check`.
8. **N13 (القفل 2 وI12 غير مفروضين آليًا على هوية الجلسة `hisabat-isa`)** يحتاج قرار عيسى قبل الدمج، كما في الجولة 1.

## ما لم أستطع قياسه

- إعدادات GitHub: حماية main، وقواعد البيئتين، ومصدر الفحص المطلوب.
- هل يشغّل GitHub workflow باسم فيه `"`.
- تشغيل `backup.yml` و`release.yml` الفعلي على الإنتاج (ممنوع). شغّلت نصوص خطواتهما محليًا بدائل فقط.

الحكم: BLOCKED_FOR_CORRECTION
