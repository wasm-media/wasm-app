#!/usr/bin/env bash
# فحص قراءة فقط على مشروع حيّ بالمفتاح العام وحده (بروتوكول §2 خطوة 7، P17، I5، N12):
#  1) التسجيل الذاتي مرفوض لسببه: 422 signup_disabled
#  2) مزوّد البريد يعمل: دخول ببيانات خاطئة = 400 invalid_credentials (لا 422 email_provider_disabled)
#  3) بلا دخول لا يُقرأ شيء: /rest/v1/jobs = 401 أو 403 برمز 42501
# لا يطبع إلا رموز الحالة. env: SUPABASE_URL PUBLIC_KEY
set -uo pipefail
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
req() { curl -s -o "$T/r.json" -w '%{http_code}' "$@"; }
c=$(req -X POST "$SUPABASE_URL/auth/v1/signup" -H "apikey: $PUBLIC_KEY" -H 'content-type: application/json' \
  -d '{"email":"probe-intruder@wasm.invalid","password":"Probe-intruder-123"}'); e=$(jq -r '.error_code // empty' "$T/r.json" 2>/dev/null)
[ "$c" = 422 ] && [ "$e" = signup_disabled ] && echo "ok   P17 self-signup refused ($c $e)" || { echo "FAIL P17 self-signup ($c ${e:-no error_code})"; bad=1; }
c=$(req -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" -H "apikey: $PUBLIC_KEY" -H 'content-type: application/json' \
  -d '{"email":"probe-nobody@wasm.invalid","password":"not-a-real-password"}'); e=$(jq -r '.error_code // empty' "$T/r.json" 2>/dev/null)
[ "$c" = 400 ] && [ "$e" = invalid_credentials ] && echo "ok   email login provider enabled ($c $e)" || { echo "FAIL email login provider ($c ${e:-no error_code})"; bad=1; }
c=$(req "$SUPABASE_URL/rest/v1/jobs?select=job_number&limit=1" -H "apikey: $PUBLIC_KEY"); e=$(jq -r '.code // empty' "$T/r.json" 2>/dev/null)
{ [ "$c" = 401 ] || [ "$c" = 403 ]; } && [ "$e" = 42501 ] && echo "ok   I5 anonymous read refused ($c $e)" || { echo "FAIL I5 anonymous read ($c ${e:-no code})"; bad=1; }
[ $bad -eq 0 ] && echo "PASS production probe" || { echo "FAIL production probe"; exit 1; }
