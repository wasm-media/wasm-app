#!/usr/bin/env bash
# حسابات الموظفين بلا بريد (D29): لكل اسم دخول في staff.txt حساب بريده الداخلي staff.<الاسم>@wasmmedia.net
# وكلمة سره = الاسم نفسه (قرار عيسى وخطره المقبول كتابةً، D29). الحساب الموجود لا يُمس، إلا إن ذُكر اسمه في
# STAFF_RESET فتُعاد كلمة سره إلى الاسم ("نسيت كلمة السر"). الدور والاسم من بصمة البريد في private.partner_seed
# عبر الـtrigger (P18) — لا يُنشأ حساب بلا بصمة مدموجة. لا يطبع إلا أسماء الدخول ونتيجة كل واحد.
# env: SUPABASE_URL SERVICE_KEY [STAFF_FILE] [STAFF_RESET] [MIGRATIONS_DIR]
set -euo pipefail
FILE=${STAFF_FILE:-supabase/staff.txt}; MIG=${MIGRATIONS_DIR:-supabase/migrations}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
H=(-H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" -H 'content-type: application/json')
mapfile -t U < <(grep -vE '^[[:space:]]*(#|$)' "$FILE" | sed -E 's/[[:space:]]+//g' | tr '[:upper:]' '[:lower:]')
[ ${#U[@]} -gt 0 ] || { echo "FAIL: no usernames in $FILE"; exit 1; }
for u in "${U[@]}"; do
  [[ "$u" =~ ^[a-z][a-z0-9._-]{7,}$ ]] || { echo "FAIL: bad username '$u' (8+ characters: a-z 0-9 . _ -)"; exit 1; }
  h=$(printf '%s' "staff.$u@wasmmedia.net" | sha256sum | cut -d' ' -f1)
  grep -rqF "'$h'" "$MIG" || { echo "FAIL: $u has no seed fingerprint in $MIG — no account created"; exit 1; }
done
IFS=',' read -ra RESET <<< "$(printf '%s' "${STAFF_RESET:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
for r in "${RESET[@]}"; do
  [ -z "$r" ] || printf '%s\n' "${U[@]}" | grep -qxF "$r" || { echo "FAIL: staff_reset '$r' is not in $FILE"; exit 1; }
done
code=$(curl -s -o "$T/users.json" -w '%{http_code}' "$SUPABASE_URL/auth/v1/admin/users?per_page=1000" "${H[@]}")
[ "$code" = 200 ] || { echo "FAIL: list users (http $code)"; exit 1; }
for u in "${U[@]}"; do
  e="staff.$u@wasmmedia.net"
  id=$(jq -r --arg e "$e" '[.users[] | select((.email // "" | ascii_downcase) == $e)][0].id // empty' "$T/users.json")
  if [ -z "$id" ]; then
    body=$(jq -n --arg e "$e" --arg p "$u" '{email: $e, password: $p, email_confirm: true}')
    code=$(curl -s -o "$T/r.json" -w '%{http_code}' -X POST "$SUPABASE_URL/auth/v1/admin/users" "${H[@]}" -d "$body")
    [ "$code" = 200 ] || { echo "FAIL: create $u (http $code $(jq -r '.error_code // .msg // empty' "$T/r.json" 2>/dev/null))"; exit 1; }
    echo "created  $u"
  elif printf '%s\n' "${RESET[@]}" | grep -qxF "$u"; then
    body=$(jq -n --arg p "$u" '{password: $p}')
    code=$(curl -s -o "$T/r.json" -w '%{http_code}' -X PUT "$SUPABASE_URL/auth/v1/admin/users/$id" "${H[@]}" -d "$body")
    [ "$code" = 200 ] || { echo "FAIL: reset $u (http $code)"; exit 1; }
    echo "reset    $u"
  else
    echo "exists   $u"
  fi
done
echo "PASS staff accounts (${#U[@]})"
