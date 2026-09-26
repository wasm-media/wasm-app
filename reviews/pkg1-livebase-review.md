reviewed: commit 30073761c700

# مراجعة مستقلة: حزمة الإصلاح «قاعدة main الحية»، الجولة 2 من 2

- **النطاق:** الحزمة 1، الـPR `wasm-media/wasm-app#1`، الفرع `pkg1/bootstrap`. نطاق الجولة 2 وحده: أسباب رفض الجولة 1، والرجوع، والثوابت، والأمن.
- **ما قرأته:** البروتوكول 1.2.2، و`INVARIANTS` (I1 إلى I13)، و`MISTAKES` (حتى N13)، والشريحة 0 (0أ، «لا يستطيع» والبنود 2.1 إلى 2.9)، وورقة الحزمة P1 (§3.3 معتمد مسبقًا)، وتقرير الجولة 1 `reviews/pkg1-livebase-review-r1.md`.
- **الفرق:** `git diff 39dcde5a972a 30073761c700` فيه سطر واحد في `.github/workflows/guard.yml`:
  `types: [opened, synchronize, reopened]` صار `types: [opened, synchronize, reopened, edited]`.
  - تأكدت أن الفرق خارج `reviews/` حتى رأس الفرع (d426921) هو هذا السطر وحده.
  - خطوات `run` المستخرجة آليًا من الـyml متطابقة حرفيًا بين 39dcde5 و3007376. قارنتها بـ`diff` بعد الاستخراج بـPython/YAML.
- **حالة المستودع:** لم أعدّل شيئًا في `/home/user/wasm-app`. كل التجارب جرت على نسخة في الـscratchpad (`r2/` و`sim2/`).

## أسباب رفض الجولة 1

لا يوجد. الجولة 1 لم تُسجّل أي مانع. هذا الـcommit يعالج BACKLOG 2 منها: «types بلا edited».

---

## 1) الاختبارات: شغّلتها بنفسي على 3007376

| الأمر (في النسخة `r2` على 30073761c700) | المخرج |
|---|---|
| `bash tests/ci/guard_selftest.sh` | 24 من 24 `ok`: 23 فخًّا FAIL، والطلب السليم «clean PR with approved report → PASS». ثم `PASS guard selftest (24)`، ورمز الخروج 0 |
| `/tmp/actionlint .github/workflows/*.yml` | لا مخرجات، ورمز الخروج 0. يقبل `edited` نوعًا صالحًا لـ`pull_request_target` |
| `supabase stop --no-backup`، ثم `supabase start -x realtime,storage-api,imgproxy,studio,edge-runtime,logflare,vector` (قاعدة جديدة، والترحيلات من النسخة)، ثم `bash tests/ci/run_real.sh` | `sql: WASM_TEST_RESULTS 152 total, 152 ok, FAILED: none` · `PASS concurrency (3 checks)` · `PASS [390x844/ar-PS] 53 checks` · `PASS [1440x900/en-US] 53 checks` · `PASS real`، ورمز الخروج 0 |
| `bash tests/ci/run_mock.sh` | `PASS [390x844/ar-PS] 45 checks` · `PASS [1440x900/en-US] 45 checks` · `PASS ui (both viewports)` · `PASS mock`، ورمز الخروج 0 |

**CI على GitHub:**

| التشغيل | الـcommit | النتيجة |
|---|---|---|
| 36187916829 | 3007376 | `guard-selftest` success. `ui-mock` و`supabase-real` ألغاهما (cancelled) دفعُ d426921 بعده بـ26 ثانية |
| 36187959792 | d426921 (رأس الـPR) | الوظائف الثلاث success |

- شجرة d426921 = شجرة 3007376 + ملفات `reviews/` فقط.
- `main` البعيد ما زال `1ac40db` وهو `protected:false`. لذلك لم يعمل `guard.yml` (`pull_request_target`) على GitHub قط، وحاكيته بـgit (§3).

## 2) محاولات الكسر بالهويات

على المكدّس الحقيقي بعد `run_real`، بطلبات REST برموز دخول فعلية: `employee@wasm.test` و`partner1@wasm.test`، ومرة بلا دخول (المفتاح العام وحده).

| المحاولة | موظف | شريك | بلا دخول |
|---|---|---|---|
| قراءة `jobs` و`job_notes` و`job_stage_log` و`people` | 200 `[]` | 200 بيانات (مسموح له) | 401 `42501` |
| قراءة `job_counter` و`user_roles` | 403 `42501` | 403 `42501` | 401 `42501` |
| `rpc/create_job` | 400 `not_partner` | 200 (أنشأ 9003، مسموح له) | 401 `permission denied for function` |
| `rpc/move_job` | 400 `not_partner` | 400 `invalid_transition` (انتقال غير صالح) | 401 |
| `rpc/cancel_job` | 400 `not_partner` | 200 `cancelled` (مسموح له) | 401 |
| INSERT أو PATCH مباشر على `jobs` | 403 `42501` | 403 `42501` | 401 `42501` |
| DELETE على `jobs` و`job_notes` و`job_stage_log` (I8) | 403 `42501` | 403 `42501` | 401 `42501` |
| PATCH على `job_stage_log` | 403 | 403 | 401 |
| رفع الصلاحية بـPATCH أو INSERT على `user_roles` | 403 `42501` | 403 | 401 |

**بعد المحاولات (psql):**
- دور الموظف ما زال `employee`.
- لم يُحذف أي سطر: الشغلات 3، و`job_notes` = 2.
- `job_stage_log` زاد من 6 إلى 7 بإلغاء الشريك، والسطر الجديد `quote → cancelled` ومعه `moved_by` (I9).

**بنود 0أ الخاصة بالحارس:** لم أجرّب أي بند بـPR حقيقي، لأن الدفع ممنوع عليّ. غطّيتها بالفحص الذاتي 24/24، وبمحاكاة `guard.yml` الجديد على الأحداث كلها (§3).

## 3) الأمن: هل يفتح `edited` ثغرة؟ لا

### القراءة

**1. الحقن من العنوان أو الوصف.** `edited` يطلقه كل من يعدّل عنوان الـPR أو وصفه أو قاعدته، والعنوان والوصف نص يتحكم فيه المهاجم. لكن `guard.yml` لا يستعمل منهما شيئًا:
- التعابير `${{ }}` في الملف أربعة فقط: `pull_request.number` و`head.sha` (مرتين) و`base.sha`.
- كلها أرقام أو sha لا يتحكم فيها كاتب الـPR بنص حر.
- كلها تمرّ عبر `env`، ولا `${{ }}` داخل `run`.
- لا `title` ولا `body` ولا `head.ref`.

**2. نسخة الـworkflow.** `pull_request_target` يأخذ الـworkflow من فرع القاعدة، و`branches: [main]` يقصره على PR قاعدته main. فالنسخة المستعملة نسخة main دائمًا، و`edited` لا يغيّر ذلك.

**3. ما لم يتغيّر.**
- `permissions: contents: read`، و`persist-credentials: false`، ولا أسرار.
- الـcheckout هو `refs/heads/main`.
- رأس الـPR يُجلب بيانات فقط، ولا يُشغَّل منه شيء.

### المحاكاة (`sim2/edited.sh`)

**الأداة:**
- `extract.py` يستخرج خطوات `guard.yml` لـ3007376 نفسه، ويفشل إن وجد تعبيرًا غير معروف.
- `trigger.py` ينمذج مرشّح GitHub الموثّق (`types` و`branches`). **هذا نموذج مني لسلوك GitHub، لا GitHub نفسه.**
- «GitHub» في المحاكاة مستودع bare فيه `refs/heads/main` و`refs/pull/1/head`.

| # | الحالة | المتوقع | الفعلي |
|---|---|---|---|
| E1 | PR سليم بتقرير معتمد، والأحداث opened وsynchronize وreopened وedited | PASS في الأربعة | PASS rc=0 في الأربعة (لا رجوع) |
| E2 | BACKLOG 2 للجولة 1: PR على `feature` فيه workflow بـjob اسمه `guard` (فخ 2.2)، ويعدّل `guard.sh` | لا تشغيل ما دامت القاعدة `feature`، ثم FAIL عند تغييرها إلى main | القاعدة `feature`: no-run. بعد `edited` إلى main: RUNS، ثم `guard files touched: .github/guard/guard.sh .github/workflows/fake.yml` و`guard: FAIL` rc=1. مع yml الجولة 1: no-run، وهذه هي الثغرة التي أُغلقت |
| E3 | تغيير قاعدة PR سليم إلى main | PASS | PASS rc=0 |
| E4 | `edited` بعنوان عدائي: `` $(touch /tmp/pwn_r2)`touch /tmp/pwn_r2`"; exit 0; # `` مصدَّر في البيئة | كـE1، ولا يُنشأ أي ملف | PASS rc=0، ولا وجود لـ`/tmp/pwn_r2` |
| E5 | تعديل العنوان على PR يلمس `guard.sh` | لا يقلب FAIL إلى PASS | synchronize: FAIL، وedited: FAIL (rc=1) |
| E6 | عيسى أضاف `web/index.html` إلى `PROTECTED` على main، ثم عُدّل عنوان PR كان قد أعطى PASS | يُعاد الحكم مقابل main الحالي | قبل: PASS. بعد `edited`: FAIL `guard files touched: web/index.html` |
| E7 | تغيير القاعدة من main إلى `feature` | لا تشغيل | no-run |
| E8 | `edited` برأس sha غير قابل للجلب | يُغلق على الفشل | rc=128، فالخطوة تفشل |

### الخلاصة الأمنية

- `edited` لا يضيف طريق تنفيذ ولا طريق حقن ولا سرًّا.
- كل ما يفعله أنه يشغّل نسخة main من الحارس مرة إضافية، مقابل main الحالي، على `head.sha` الحالي.
- تعديل العنوان لا يستطيع أن يقلب FAIL إلى PASS إلا إن سمح main الحالي نفسه بذلك، وهذا هو الحكم الصحيح.
- لا مشكلة TOCTOU جديدة: جهة الرأس مثبّتة على `head.sha` في الحدث، وجهة القاعدة سحبة واحدة. المتبقي «main يتقدّم بعد التشغيل» هو نفسه، ولم يتغيّر.

## 4) الرجوع: لا رجوع

| ما فحصته | النتيجة |
|---|---|
| خطوات التشغيل | متطابقة حرفيًا مع 39dcde5 |
| الفحص الذاتي | 24/24 |
| الطلب السليم | يمرّ في كل أنواع الأحداث (E1، E3) |
| الهجوم | يُمسك في كل أنواع الأحداث (E2، E5، E6) |
| `run_real` | 152، و3، و53×2 |
| `run_mock` | 45×2 |
| `ci.yml` و`guard.sh` وملفات الاختبار | لم تُمسّ |

**سلوك جديد مقصود:** تعديل عنوان الـPR أو وصفه يعيد تشغيل الحارس. هذا مساوٍ لزر «Re-run»، وأصح.

## 5) الثوابت

| # | الحالة | الدليل |
|---|---|---|
| I1، I2 | سليم | الموظف يقرأ `[]` من `jobs` و`job_notes` و`job_stage_log` و`people` |
| I3 | سليم | الموظف يُرفض بـ`not_partner` في `create_job` و`move_job` و`cancel_job` |
| I4 | سليم | فحوص I4 ضمن الـ152 خضراء |
| I5 | سليم | بلا دخول: 401 على كل جدول ودالة جرّبتها |
| I6، I7، I11 | لا مساس | خارج الفرق، والفحوص خضراء |
| I8 | سليم | DELETE مرفوض من الأدوار الثلاثة، ولم يُحذف أي سطر |
| I9 | سليم | إلغاء الشريك أضاف سطرًا في السجل فيه المنفّذ والحالتان |
| I10 | سليم، ومقوّى | الطريق الذي ترك الحارس بلا تشغيل عند تغيير القاعدة إلى main أُغلق (E2). المتبقي RB (دفع مباشر إلى main) كما هو |
| I12 | كما كان | غير مفروض آليًا على جلسة المنفّذ (N13)، وغير مقيس هنا |
| I13 | سليم | فحوص الخروج خضراء في المحاكي والحقيقي |

## 6) الاختبار الأحمر في CI

- لا اختبار جديد في هذا الـcommit، والتغيير سطر في `guard.yml`.
- لا يوجد فحص آلي دائم يُحمّر لو حُذف `edited` لاحقًا، وهذا امتداد لـBACKLOG 1 من الجولة 1.
- أثبتُّ الفرق بالمحاكاة وحدها: yml الجولة 1 يعطي no-run في مسار تغيير القاعدة، والجديد يعطي FAIL (E2).

---

## BACKLOG (لا توقف بها)

1. **لا فحص دائم لـ`guard.yml` نفسه.** هو BACKLOG 1 من الجولة 1، ويشمل الآن `types`.
   - فخ في CI يستخرج `on:` والخطوات ويتحقق من أمرين:
     - `edited` موجود في `types`.
     - القاعدة القديمة `base.sha` تُمسك.
   - هذا الفخ كان سيُمسك أي رجوع.
2. **فخ 2.2 مع تغيير القاعدة أو دفع لاحق:**
   - بعد E2 صار على الـsha نفسه فحصان باسم `guard` من تطبيق GitHub Actions نفسه: FAIL من الحارس الحقيقي، وPASS من workflow الـPR لو شُغّل بـ`pull_request`.
   - أيهما يعتمده الفحص المطلوب أمر يجب أن يُقاس حيًّا عند ضبط حماية main. هو قائم قبل هذا الـcommit، ولم يُدخله `edited`.
3. **CI على 3007376 أُلغي** (`ui-mock` و`supabase-real`)، لأن دفع d426921 جاء بعده بثوانٍ.
   - الشجرة نفسها (زائد `reviews/`) خضراء على d426921، وأعدتُ الاختبارات محليًا.
   - للتوثيق فقط: دفع commit التقارير قبل اكتمال CI على commit البناء يترك commit البناء بلا تشغيل مكتمل خاص به.
4. **باقٍ من الجولة 1 كما هو:**
   - BACKLOG 3: RB، دفع fast-forward مباشر إلى main.
   - BACKLOG 4: «Require branches to be up to date» غير مضبوط، وmain `protected:false`.
   - BACKLOG 5: `guard.yml` لم يعمل قط على GitHub. أُضيف إليه الآن: سلوك `edited` نفسه يُقاس حيًّا بعد أول دمج.
   - BACKLOG 6.

الحكم: معتمد
