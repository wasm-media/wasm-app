reviewed: commit 526f626c38d5

# مراجعة مستقلة: حزمة الإصلاح «حارس المسارات» داخل الحزمة 1، الجولة 2 من 2

- **الـcommit المراجَع:** `526f626c38d5b789e1ca38666eabb19e30c5f0ab`، وهو رأس الـPR wasm-media/wasm-app#1 وقت المراجعة (`pull_request_read`: `head.sha` نفسه، `base.sha` = `1ac40db`، `mergeable_state: clean`).
- **الفرق المفحوص:** `git diff a39337b07088 526f626c38d5`، ويمسّ 5 ملفات: `guard.sh`، و`guard.yml`، و`guard_selftest.sh`، و`backup.yml`، و`ci.yml` (اسم الخطوة فقط).
- **نطاق الجولة 2 (§3.2):** أسباب رفض الجولة 1، والرجوع، والثوابت، والأمن. ما عدا ذلك في BACKLOG.
- **بيئة العمل:**
  - نسخة نظيفة من الـcommit عبر `git archive` في `/tmp/rg2`.
  - نسخة فيها `guard.sh` من a39337b في `/tmp/rg2old`، للمقارنة وإثبات الأحمر.
  - مستودعات هجوم مؤقتة تحت `/tmp/ra2`. السكربتات: `lib.sh`، و`scen.sh`، و`s6.sh`، و`stale.sh`، و`behind.sh`، و`reg.sh`، و`bk/drive.sh`.
- **ما لم ألمسه:** لم أعدّل شيئًا في `/home/user/wasm-app` (الشجرة نظيفة، والرأس `526f626c38d5`). لا commit ولا push، ولم أدفع شيئًا إلى GitHub، ولم ألمس الإنتاج ولا أي سر.

---

## 1) الاختبارات: ما شغّلته بنفسي

| الأمر | المخرج |
|---|---|
| `bash tests/ci/guard_selftest.sh` (من `/tmp/rg2`، git 2.43.0، bash 5.2.21) | 24 من 24 `ok`، ثم `PASS guard selftest (24)`، ورمز الخروج 0. السجل في `/tmp/review/r2g_guard_selftest.log` |
| الفحص نفسه في نسخة `/tmp/rg2v` تطبع سطر `::error` لكل فخ | كل فخ جديد يُرفض **للسبب المقصود**:<br>t22: `test files deleted: tests/sql/concurrency.sh` (تغيّر النوع T)<br>t23: `guard files touched: .github/guard/guard.sh`<br>t24: `guard files touched: tests/COUNT` |
| `/tmp/actionlint .github/workflows/*.yml` | لا مخرج، ورمز الخروج 0 |
| `supabase stop --no-backup` (من `/tmp/rg`)، ثم `supabase start -x realtime,storage-api,imgproxy,studio,edge-runtime,logflare,vector` (من `/tmp/rg2`، CLI 2.118.0) | طُبّقت الترحيلات الثلاث على قاعدة جديدة |
| `bash tests/ci/run_real.sh` | رمز الخروج 0، و106 أسطر `ok`. السجل في `/tmp/review/r2g_run_real.log`، وأهم ما فيه:<br>`sql: WASM_TEST_RESULTS 152 total, 152 ok, FAILED: none`<br>`PASS concurrency (3 checks)`<br>`PASS [390x844/ar-PS] 53 checks` · `PASS [1440x900/en-US] 53 checks`<br>`PASS real` |
| `bash tests/ci/run_mock.sh` | `PASS [390x844/ar-PS] 45 checks` · `PASS [1440x900/en-US] 45 checks` · `PASS mock`، ورمز الخروج 0. السجل في `/tmp/review/r2g_run_mock.log` |

**CI على GitHub** (قرأت السجلات بنفسي): التشغيل 36185267780 على 526f626 أخضر في مهامه الثلاث (guard-selftest، وui-mock، وsupabase-real).
- سجل guard-selftest فيه الـ24 كلها `ok`، ثم `PASS guard selftest (24)`، والـshell فيه `bash -e {0}`، وgit على الـrunner 2.55.0.
- workflow `guard` نفسه لا يعمل على هذا الـPR، لأنه `pull_request_target` وmain فيه commit واحد بلا `guard.yml`. فلا يوجد تشغيل حقيقي لـ`guard.yml` الجديد على GitHub.

## 2) كسر «لا يستطيع» بهويات حقيقية

المكدّس الحقيقي، والهويات من GoTrue بعد `run_real.sh`: `employee@wasm.test` و`partner1@wasm.test`، وطلب ثالث بلا دخول. هذا الـcommit لا يمسّ القاعدة ولا الواجهة، فالهدف هنا التأكد من أن شيئًا لم يرجع.

| المحاولة | بلا دخول | موظف | شريك |
|---|---|---|---|
| قراءة `jobs` / `job_notes` | 401 42501 | 200 `[]` / 200 `[]` | 200 (بيانات) |
| قراءة `user_roles` | 401 | 403 42501 | 403 42501 |
| إدراج في `user_roles`، أو إدراج مباشر في `jobs` | 401 | 403 | 403 |
| `DELETE jobs` و`DELETE job_stage_log` | 401 | 403 42501 | 403 42501 |
| `PATCH jobs` (stage/title)، و`PATCH job_counter` | 401 | 403 | 403 |
| `rpc/create_job` | 401 42501 | 400 `not_partner` | 200 (9003) |
| `rpc/move_job` و`rpc/cancel_job` | 401 42501 | 400 `not_partner` | يصل للدالة (`invalid_stage`) |
| `/auth/v1/signup` | 422 `signup_disabled` | — | — |

الشغلة 9001 قبل المحاولات وبعدها هي نفسها: `منيو مطبوع`، `cancelled`. السيرفر رفض كل محاولة.

**بنود «لا يستطيع» في 0أ الخاصة بالحارس** (تمرير guard بتعديل ملفاته، وإنقاص العدد) اختبرتها في §4.

## 3) الأحمر قبل البناء

- **لا يوجد تشغيل CI أحمر للفخاخ t22 إلى t24.** أُضيفت في commit الإصلاح نفسه (التشغيل 36185267780 أخضر، والذي قبله 36183253320 على a39337b لا يحويها). هذه مخالفة إجرائية لـ§2 خطوة 2، كما في الجولات السابقة.
- **أعدت إنتاج الأحمر محليًا:** شغّلت `guard_selftest.sh` الجديد مع `guard.sh` من a39337b (في `/tmp/rg2old`)، فكانت النتيجة:
  ```
  BAD  test file turned into a symlink → PASS (want FAIL)
  BAD  criss-cross merge reverts a guard file → PASS (want FAIL)
  BAD  criss-cross merge lowers the test count → PASS (want FAIL)
  FAIL guard selftest   (rc=1)
  ```
  أي أن الفخاخ ترى الخلل فعلًا. السجل في `/tmp/review/r2g_red_old_guard.log`.

## 4) مانع الجولة 1 والصنف كله

### 4.1 إعادة خطوات المانع كما هي

الأمر: `bash /tmp/ra/b1.sh <guard>` و`bash /tmp/ra/b1_count.sh <guard>`.

| الحارس | b1 (إرجاع `guard.sh`) | b1_count (خفض `tests/COUNT`) |
|---|---|---|
| a39337b | قاعدتا دمج؛ `guard: PASS`، و`rc=0` | `guard: PASS`، و`rc=0` |
| **526f626** | قاعدتا دمج؛ **`guard: FAIL`، و`rc=1`**؛ والسبب `guard files touched: .github/guard/guard.sh` | **`guard: FAIL`، و`rc=1`**؛ والسبب `guard files touched: tests/COUNT` |

(سطر «after merge on main» في السكربت يدمج دائمًا دون النظر إلى نتيجة الحارس، فلا دلالة له هنا.)

**مانع الجولة 1 بصيغته المقيسة (قواعد دمج متعددة، و`BASE` = رأس main) أُغلق.**

### 4.2 بقية الصنف: الحارس من الـcommit نفسه، ونتائج `/tmp/ra2/scen.sh` و`s6.sh` و`behind.sh` و`reg.sh`

| الحالة | الناتج |
|---|---|
| S1: قواعد دمج متعددة + إرجاع `guard.sh` + كود + تقرير اعتماد | FAIL: `guard files touched: .github/guard/guard.sh` |
| S1b: الشيء نفسه بلا commit كود، بدمج مُرجِع فقط | FAIL: ملف الحراسة، ومعه غياب التقرير |
| **S2: PR سليم بقاعدتَي دمج** (يُبقي قاعدة عيسى) + كود + تقرير | **PASS**، والدمج الحقيقي يُبقي قاعدة عيسى |
| S3: دمج شرير داخل الـPR، حلّه يعدّل `guard.sh` | FAIL |
| S3b: دمج شرير يضيف كودًا، والتقرير على commit قبله | FAIL (`LAST` = commit الدمج) |
| S5: PR متعارض مع main | FAIL: `PR does not merge cleanly into base (merge-tree rc=1)`. ويثبت هذا أن `PIPESTATUS` يلتقط رمز `merge-tree` |
| S6: HEAD دمج لـcommitين من main (وكلاهما سلف لـBASE) بشجرة main القديمة، يُرجع كودًا معتمدًا بلا تقرير (الترتيبان)؛ وS6c: الشيء نفسه بقواعد متعددة على `web/index.html` | FAIL: `LAST` = commit الدمج، ولا تقرير له. git يُظهر الدمج ولا يبسّطه |
| S7: تاريخ غير مرتبط (orphan) | FAIL: `merge-tree rc=128` |
| S8: HEAD = BASE، أو HEAD سلف لـBASE | PASS، ولا شيء يُدمج |
| R1: PR متأخر عن main (عيسى عدّل `guard.sh` و`COUNT` بعد تفرّع الـPR)، والـPR سليم + تقرير | PASS، وهذا صحيح لأن الـPR لا يُرجع شيئًا |
| R2: تقرير جديد، وعلى main تقرير قديم بمسار آخر | PASS |
| R3: PR حُدّث بدمج main بقاعدة واحدة + كود + تقرير | PASS |
| R4: commit كود بعد التقرير | FAIL |
| الفئات السابقة: تغيير النمط، و`guard.sh` symlink إلى `/dev/null`، و`tests/ci` يصير gitlink، وملف اختبار يصير gitlink (T)، وتقرير CRLF، وNBSP بعد الحكم، وسطر جديد في اسم محمي، ونقل `.github` مع symlink، و`COUNT` إلى `count` | كلها FAIL للسبب المقصود. حالة «ملف اختبار يصير gitlink» تُمسك الآن بـ`test files deleted` (أغلق BACKLOG 3 من الجولة 1) |

### 4.3 ما بقي مفتوحًا من الصنف: «base قديم». هو المانع أدناه

---

## المانع (BLOCKED_FOR_CORRECTION)

### المانع 1: الحارس يقارن بـ`pull_request.base.sha` من حمولة الحدث، لا برأس main الحالي
حين تكون هذه القيمة أقدم من رأس main، يمرّ PR «حدّث فرعه من main» وأرجع ملف حراسة أو خفّض `tests/COUNT`، وخروج الحارس PASS. هذا يخرق القفل 3، و0أ بند 2.6 («يلمس ملفات الحراسة … فئة بفئة»)، وI10 («عدد الاختبارات لا ينقص»). وهو صنف «base قديم» الذي فُصلت هذه الحزمة لإغلاقه، وذكره تقرير الجولة 1 متغيّرًا مفتوحًا للمانع نفسه.

**الموضع:**
- `.github/workflows/guard.yml`، الأسطر 16 و29 و31:
  - الـcheckout والـ`BASE` كلاهما `${{ github.event.pull_request.base.sha }}`.
  - الـcommit عالج توقيت الحدث لجهة الرأس فقط: جعل `HEAD_SHA` مثبّتًا من الحدث. ولم يعالج جهة القاعدة: لا يجلب رأس `base.ref` الحالي، ولا يتحقق من أن `BASE` هو رأس main.
- `.github/guard/guard.sh`، الأسطر 11 إلى 15:
  - الحارس يبني `merge-tree "$BASE" "$HEAD"` ويصفه بأنه «ما سيدمجه GitHub فعلًا».
  - هذا صحيح فقط إن كان `BASE` هو رأس main. أما إن كان أقدم، فشجرة الدمج التي يفحصها ليست ما سيدخل main.
- **ويترتب عليه أيضًا:** الـcheckout على `base.sha` القديم يشغّل **نسخة الحارس القديمة نفسها**، أي قبل تشديد عيسى.

**هل تكون `base.sha` في حدث `synchronize` قديمة على GitHub؟ الأدلة العامة، ولم أقسها على هذا المستودع لأني ممنوع من الدفع:**
- WordPress/wordpress-playground PR #4336 (https://github.com/WordPress/wordpress-playground/pull/4336) يوثّق من تشغيلات حقيقية حدثَي `synchronize` بفارق ثوانٍ. الثاني حمل `base.sha` = `c3655c45ef`، وهو **أقدم بـcommitين** من رأس trunk (`fd283fe9bb`)، بعد أن أُعيد تأسيس الرأس على الأحدث. ونصّه: «not guaranteed to be the current base tip — concurrent synchronize events can even carry different, stale values».
- GitHub community discussion #59677 (https://github.com/orgs/community/discussions/59677): «The value of `${{ github.event.pull_request.base.sha }}` is not updated on every commit to the PR». وفيه رأي آخر بأنها تُحدَّث عند الإنشاء أو عند force-push. لا يوجد جواب رسمي من GitHub.
- فافتراض الجولة 1 («أغلب ظني أن synchronize يحدّث base.sha») لا يصمد. والحارس لا يملك أي ضمان بأن `BASE` هو رأس main.

**الشرط المسبق:** PR مفتوح (الـPR الحالي مفتوح منذ ساعات) ← عيسى يعدّل ملف حراسة أو `tests/COUNT` مباشرة على main، وهو المسار الذي يصفه الحارس نفسه ← يُحدَّث الـPR من main بدفع عادي، سواء بزر «Update branch» أو بـ`git merge main`، ويُبقي حلّ الدمج النسخة القديمة من الملف، عمدًا أو خطأً.
- حماية main الآن `protected:false`.
- خيار «Require branches to be up to date» غير مضبوط، ولا merge queue.

**خطوات الإعادة (محليًا):**
```
bash /tmp/ra2/stale.sh /tmp/rg2/.github/guard/guard.sh .github/guard/guard.sh '# isa: new rule'
bash /tmp/ra2/stale.sh /tmp/rg2/.github/guard/guard.sh tests/COUNT x
```
ما يفعله السكربت:
```
M0 = main؛ فرع pr من M0 + سطر في web/app.js        (الحدث: base.sha = M0)
main: عيسى يضيف قاعدة إلى guard.sh (أو يرفع sql 152 ← 160 في tests/COUNT) ← M1
pr: git merge --no-commit M1 ; git checkout M0 -- <الملف> ; commit "Merge branch main into pr"
    ثم سطر كود + تقرير اعتماد على آخر commit كود
guard.sh M0 HEAD   (ما يمرّره guard.yml إن حمل الحدث base.sha قديمًا)
guard.sh M1 HEAD   (رأس main الحقيقي)
git merge pr في main
```

**المتوقع:**
- مع `BASE` = M0: `::error::guard files touched: …` ثم `guard: FAIL`، ورمز الخروج 1، لأن الدمج سيُرجع ملف حراسة على main.
- أو، على الأقل، أن يرفض الحارس `BASE` ليس هو رأس main.

**الفعلي:**
```
guard with event base.sha=M0 (stale):  guard: PASS rc=0
guard with current main tip M1:        ::error::guard files touched: .github/guard/guard.sh guard: FAIL rc=1
after the real merge into main: Isa's line count in .github/guard/guard.sh = 0
--- tests/COUNT
guard with event base.sha=M0 (stale):  guard: PASS rc=0
guard with current main tip M1:        ::error::guard files touched: tests/COUNT guard: FAIL rc=1
after the real merge into main: sql 152
```
أي: الحارس أخضر، ثم الدمج الحقيقي يحذف قاعدة عيسى، أو يعيد العدّ من 160 إلى 152.

**ملاحظات:**
- الثغرة نفسها في a39337b: النتيجة نفسها على `/tmp/rg2old`. فهي ليست رجوعًا، لكنها الجزء غير المغلق من صنف المانع.
- الـcommit يصرّح بأنه يفحص «ما سيدمجه GitHub فعلًا»، وهذا لا يتحقق إلا بقاعدة = رأس main.
- الفخاخ لا تغطي أي حالة يكون فيها `BASE` أقدم من main.
- للعلم فقط، دون إصلاح: جلب رأس `github.event.pull_request.base.ref` الحالي في `guard.yml` واستعماله قاعدة (مع تشغيل نسخة الحارس منه)، أو الفشل إن اختلف `base.sha` عنه. مع ذلك، ضبط «Require branches to be up to date» عند ضبط حماية main، حتى لا يُدمج PR فُحص على main أقدم.
- **ما لم أقسه:** قِدم `base.sha` في حدث على هذا المستودع تحديدًا، لأنه يحتاج دفعًا إلى GitHub وهو ممنوع عليّ. قياسه ممكن بـPR تجريبي: يُفتح الـPR، ثم commit على main، ثم دفع عادي إلى الـPR، مع طباعة `base.sha` ورأس main في سجل الحارس.

---

## 5) الرجوع

- **الفحص الذاتي:** الفخاخ الـ21 السابقة كلها ما زالت FAIL، والطلب السليم t11 ما زال PASS، محليًا وفي CI.
- **الطلبات السليمة بأشكالها** (قواعد متعددة، أو متأخر عن main، أو محدَّث بدمج) تمرّ (§4.2).
- **الاختبارات:** SQL 152، والتزامن 3، والحقيقي 53×2، والمحاكي 45×2.
- **الرفض بالهويات** كما في §2.
- **سلوك جديد مقصود:** PR متعارض مع main صار يفشل في الحارس برسالة «update the PR». لا أعدّه رجوعًا، لأن GitHub لا يدمج PR متعارضًا أصلًا.
- **`ci.yml`:** «23 trap PRs and pass 1 clean PR» صحيح، فالمجموع 24.

## 6) الأمن في التغييرات الجديدة

### `guard.sh`
- **ما يُنفَّذ على الـPR:** `merge-tree` و`diff` و`log` و`show` فقط، على كائنات git. لا `eval`، ولا تنفيذ لأي ملف من الـPR.
- **مشغّلات الدمج:** `merge-tree` لا يشغّل مشغّل دمج مخصصًا إلا بإعداد في `.git/config`، والـPR لا يتحكم به. والـcheckout هو main.
- **الفشل مغلق:** عند التعارض، أو فشل `merge-tree` (بما فيه SIGPIPE)، أو تاريخ غير مرتبط، يخرج الحارس 1 (S5 وS7).
- **الأسماء:** ما زالت تُقرأ بـ`-z` و`--no-renames`، وتُطبع بـ`%q`.

### `guard.yml`
- `HEAD_SHA` و`PR` يُمرَّران عبر `env` ومقتبسان. لا حقن `${{ }}` داخل `run`، و`actionlint` نظيف.
- `persist-credentials: false`، و`contents: read`، ولا أسرار. والحارس يُشغَّل من نسخة `base.sha`، لا من الـPR.
- **فالحارس ما زال لا يشغّل كود الـPR** (0أ بند 2.9).
- تثبيت `head.sha` يغلق BACKLOG 4 من الجولة 1 (TOCTOU لجهة الرأس). أما جهة القاعدة فهي المانع أعلاه.

### `backup.yml`، خطوة الاستعادة (`set +e`)
شغّلت نصوص الخطوات مستخرَجة من الـYAML الجديد عبر `/tmp/ra2/bk/drive.sh`:
- **بيئة التشغيل:** `bash -e` كما في GitHub، مع تقليد شرطَي `if:`.
- **المدخلات:** مستودع bare بدل مستودع النسخ، ونسخ حقيقية من المكدّس المحلي.

| الحالة | الاستعادة | رفع التقرير | الحكم | الملفات المرفوعة | ما بقي في `restore/` |
|---|---|---|---|---|---|
| نسخة سليمة | `rc=0` | مرفوع (`rc=0` في التقرير المفكوك) | `PASS restore test`، خروج 0 | 4 | التقرير المشفّر فقط |
| نسخة فاسدة (صف مكرر) | `rc=1`، ونجاح الخطوة | **مرفوع** (فيه خطأ psql مشفّرًا) | `FAIL restore test (rc=1)`، خروج 1 | 4 | التقرير المشفّر فقط، و`data.sql` ممسوح |
| ملف مشفّر مبتور (فك التشفير يفشل) | `rc=1` | مرفوع | FAIL، خروج 1 | 4 | التقرير المشفّر فقط |

- **السجل العام** لخطوة الاستعادة عند الفشل: رسالة «Stopped services» من CLI، ثم `FAIL: restore`. صفر مطابقة لأي قيمة أو عدد من البيانات.
- **أُغلق BACKLOG 1 من الجولة 1.** ولا ثغرة جديدة:
  - `set +e` لا يجعل الفشل نجاحًا، لأن الحكم مبني على `rc` لا على نتيجة الخطوة.
  - فشل فك التشفير يؤدي إلى ملف فارغ أو ناقص، فيفشل `restore_check.sh` بـ«table missing» أو «restore».
  - مفتاح النشر ما زال في خطوتَي الرفع وحدهما.

## 7) الثوابت

| # | الحالة | الدليل |
|---|---|---|
| I1 | لا مساس | الموظف يقرأ `[]` من `jobs` و`job_notes` |
| I2، I3، I7 | لا مساس | خارج الفرق. الموظف يُرفض بـ`not_partner` |
| I4 | سليم | فحوص I4 ضمن الـ152 خضراء |
| I5 | سليم | بلا دخول: 401 على كل شيء |
| I6 | لا مساس | — |
| I8 | سليم | DELETE مرفوض من كل دور |
| I9 | سليم | فحوص السجل والتزامن خضراء |
| **I10** | **مخروق بطريق المانع 1** | `tests/COUNT` يرجع من 160 إلى 152 عبر PR، والحارس PASS، حين تكون `base.sha` قديمة (`/tmp/ra2/stale.sh`). طريق قواعد الدمج المتعددة أُغلق (t24، وb1_count) |
| I11 | لا مساس | — |
| I12 | غير مفروض آليًا على جلسة المنفّذ (N13) | قرار عيسى، وغير مقيس هنا |
| I13 | سليم | فحوص الخروج خضراء في المحاكي والحقيقي |

---

## BACKLOG (لا توقف بها)

1. **لا تشغيل CI أحمر للفخاخ t22 إلى t24.** أثبتُّ احمرارها محليًا (§3). والمخالفة نفسها تكررت في جولات هذه الحزمة كلها.
2. **`guard.yml` لم يعمل قط على GitHub**، لأن main بلا `guard.yml`. سلوك `git fetch origin "$HEAD_SHA"` وحمولة الحدث غير مقيسين إلا بعد أول دمج.
3. **`restore_check.sh`** يكتب `/tmp/expected.txt` و`/tmp/restore.log` (فيه أخطاء psql قد تحوي قيمًا) خارج `RUNNER_TEMP` ولا يمسحهما. الـrunner مؤقت ولا يطبعهما، فلا تسرّب، لكن الأنظف مسحهما مع `data.sql`.
4. **باقٍ من الجولة 1 كما هو:**
   - البند 5: مطابقة أول 12 محرفًا دون حدّ نهاية.
   - البند 6: أسماء عربية مطبوعة بـ`%q`، وهي صعبة القراءة.
   - البند 8: كشف التخطي والأسرار نصّي.
   - البند 9: `reviews/*.js` لا يُحسب كودًا.
   - والبند 2: `${{ steps.restore.outputs.rc }}` داخل `run` في خطوة رفع التقرير. قيمته رقمية من الخطوة نفسها.
5. **الحارس يرفض الآن كل PR متعارض مع main.** هذا سلوك صحيح، لكنه يعني أن كل تعارض في مسار تقرير مشترك تحت `reviews/` يُحمّر الحارس حتى يُحدَّث الـPR. الأفضل أن تكون أسماء التقارير فريدة.

الحكم: BLOCKED_FOR_CORRECTION
