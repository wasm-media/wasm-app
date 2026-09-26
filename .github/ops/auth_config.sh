#!/usr/bin/env bash
# يضبط Auth مشروع الإنتاج عبر Management API، ثم يقرؤه من جديد ويثبت كل حقل (P17، P19، N12).
# لا يطبع إلا الحقول المضبوطة هنا (غير سرية) — الردّ الكامل فيه أسرار (SMTP، hooks) فلا يُطبع أبدًا.
# env: SUPABASE_ACCESS_TOKEN PROJECT_REF SITE_URL [MGMT_API]
set -euo pipefail
API=${MGMT_API:-https://api.supabase.com}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# التسجيل الذاتي مغلق (disable_signup) ومزوّد البريد نفسه يبقى مفعّلًا (الدخول بكلمة السر) — N12
WANT=$(jq -n --arg s "$SITE_URL" '{
  disable_signup: true, external_email_enabled: true, mailer_autoconfirm: false,
  refresh_token_rotation_enabled: true, security_refresh_token_reuse_interval: 10,
  site_url: $s, uri_allow_list: $s, password_min_length: 8, mailer_otp_exp: 86400, jwt_exp: 3600 }')
code=$(curl -s -o "$T/patch.json" -w '%{http_code}' -X PATCH "$API/v1/projects/$PROJECT_REF/config/auth" \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H 'content-type: application/json' -d "$WANT")
[ "$code" = 200 ] || { echo "FAIL: PATCH auth config (http $code): $(jq -r '.message // .error // empty' "$T/patch.json" 2>/dev/null | head -c 300)"; exit 1; }
code=$(curl -s -o "$T/now.json" -w '%{http_code}' "$API/v1/projects/$PROJECT_REF/config/auth" -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN")
[ "$code" = 200 ] || { echo "FAIL: GET auth config (http $code)"; exit 1; }
echo "auth config read back (only the fields set here):"
jq --argjson w "$WANT" -S 'with_entries(select(.key as $k | $w | has($k)))' "$T/now.json"
jq -e --argjson w "$WANT" '. as $g | [$w | to_entries[] | select($g[.key] != .value) | .key] | if length == 0 then true else (("mismatch: " + join(", ")) | halt_error(1)) end' "$T/now.json" >/dev/null \
  || { echo "FAIL: production auth config does not match"; exit 1; }
echo "PASS auth config"
