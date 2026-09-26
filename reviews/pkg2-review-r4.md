reviewed: 49a08e6d6492ec1be756e649e01b2dab48e6b1c8

# مراجعة مستقلة — الحزمة 2 — تحقق من إصلاح مانع الجولة 3 (49a08e6)

**مانع الجولة 3:** قائمة ملفات الحراسة في الوثيقة الحاكمة، وفي وصف الـPR رقم 2، كانت تُسقط `docs/DECISIONS.md`.

لم أعدّل أي ملف في `/home/user/wasm-app`، ولم أدفع، ولم أكتب على GitHub. قرأت الـPR رقم 2 قراءة فقط بـ`pull_request_read`.

## 1. نطاق الفرق
```
git rev-parse 49a08e6          → 49a08e6d6492ec1be756e649e01b2dab48e6b1c8
git log --oneline 2b612df..49a08e6   → 49a08e6 (commit واحد)
git diff --name-status 2b612df 49a08e6   → M docs/slices/2-المهام-والملفات.md
```
الفرق وثائق فقط: ملف واحد، وسطران فيه.
- **عنوان القسم** صار: «ملفات الحراسة في هذه الشريحة (القاعدة: لا يمسّها PR المنفّذ — بروتوكول §0؛ الاستثناء هنا معروض على عيسى)». هذا يرفع التناقض الذي ذكرته في BACKLOG 1 من الجولة 3.
- **سطر مضاف:** «`docs/DECISIONS.md` (صفوف D27–D29 بكلمات عيسى نصًا — محمي على main ابتداءً من دمج هذا الـPR، P24)».

## 2. تطابق القائمتين مع ملفات الحراسة الممسوسة
النمط المستعمل يطابق `PROTECTED` في `.github/guard/guard.sh` (السطر 24 في 49a08e6):
```
git diff --name-only 46fbb53 49a08e6 | grep -E '^(\.github/|docs/DECISIONS|docs/00-|docs/INVARIANTS|tests/COUNT|tests/ci/|tests/ui/run_ui|CODEOWNERS)'
  .github/guard/guard.sh
  .github/ops/staff_accounts.sh
  .github/ops/storage_check.sh
  .github/workflows/ci.yml
  .github/workflows/release.yml
  docs/DECISIONS.md
  tests/COUNT
  tests/ci/guard_selftest.sh
  tests/ci/run_real.sh
```
النتيجة **9 ملفات**.

| الملف | الوثيقة (49a08e6) | وصف الـPR رقم 2 (الجدول) |
|---|---|---|
| `.github/workflows/ci.yml` | نعم | نعم |
| `tests/ci/run_real.sh` | نعم | نعم |
| `.github/workflows/release.yml` | نعم | نعم |
| `.github/ops/staff_accounts.sh` | نعم | نعم |
| `.github/ops/storage_check.sh` | نعم | نعم |
| `.github/guard/guard.sh` | نعم | نعم |
| `tests/ci/guard_selftest.sh` | نعم | نعم |
| `tests/COUNT` | نعم | نعم |
| `docs/DECISIONS.md` | نعم (مضاف) | نعم (صف مستقل) |

- القائمتان تطابقان الملفات التسعة، بلا نقص ولا زيادة.
- وصف الـPR ينص على أن «دمجك لهذا الـPR هو موافقتك عليها كلها».
- وصف الـPR يذكر جولة الوثائق وإصلاحها.
- لا تناقض مع D23 ولا D27 ولا D28 ولا D29.

**مانع الجولة 3 مُغلق.**

## BACKLOG (غير مانع)
1. رأس الـPR على GitHub ما زال b8018f3، لأن 2b612df و49a08e6 محليان ولم يُدفعا. وصف الـPR يصف القائمة المصححة، والفرع البعيد لا يحملها بعد. يلزم الدفع قبل لقاء التسليم.
2. بندا BACKLOG 2 و3 من الجولة 3 (P33 وP34 في DEFERRED، وادعاء `backup.yml`) باقيان بلا تحقق مني.

الحكم: معتمد
