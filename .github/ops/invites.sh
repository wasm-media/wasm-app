#!/usr/bin/env bash
# روابط الدخول الأولى للشريكين (P18) بلا بريد: بريد Supabase الافتراضي لا يصل إلا لأعضاء فريق المشروع
# («Email address not authorized» — وثائق Supabase)، فتُولَّد الروابط بواجهة الإدارة وتُكتب في ملف يُرفع
# إلى المستودع الخاص wasm-app-backups، ويرسلها عيسى بنفسه. لا يُطبع أي رابط ولا أي بريد في السجل.
# حساب جديد ← رابط دعوة (الـtrigger يزرعه شريكًا إن طابقت بصمته). حساب موجود ← لا شيء، إلا مع RELINK=1 ← رابط استعادة.
# env: SUPABASE_URL SERVICE_KEY PARTNER_EMAILS SITE_URL OUT [RELINK]
set -euo pipefail
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
H=(-H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" -H 'content-type: application/json')
code=$(curl -s -o "$T/users.json" -w '%{http_code}' "$SUPABASE_URL/auth/v1/admin/users?per_page=1000" "${H[@]}")
[ "$code" = 200 ] || { echo "FAIL: list users (http $code)"; exit 1; }
{ echo "# روابط الدخول الأولى — $(TZ=Asia/Hebron date '+%d/%m/%Y %H:%M') (غزة)"; echo
  echo "- كل رابط لمرة واحدة، وينتهي بعد 24 ساعة."
  echo "- افتحه على جهاز صاحبه، واكتب كلمة السر مرتين، فتفتح اللوحة."; echo; } > "$OUT"
n=0; i=0
IFS=',' read -ra EM <<< "${PARTNER_EMAILS:-}"
for raw in "${EM[@]}"; do
  e=$(printf '%s' "$raw" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'); [ -n "$e" ] || continue; i=$((i+1))
  exists=$(jq --arg e "$e" '[.users[] | select((.email // "" | ascii_downcase) == $e)] | length' "$T/users.json")
  if [ "$exists" = 0 ]; then type=invite
  elif [ "${RELINK:-0}" = 1 ]; then type=recovery
  else echo "email #$i: account exists — no link (RELINK=1 for a new one)"; continue; fi
  body=$(jq -n --arg t "$type" --arg e "$e" --arg r "$SITE_URL" '{type: $t, email: $e, redirect_to: $r}')
  code=$(curl -s -o "$T/link.json" -w '%{http_code}' -X POST "$SUPABASE_URL/auth/v1/admin/generate_link" "${H[@]}" -d "$body")
  link=$(jq -r '.action_link // .properties.action_link // empty' "$T/link.json" 2>/dev/null)
  [ "$code" = 200 ] && [ -n "$link" ] || { echo "FAIL: email #$i: generate_link $type (http $code)"; exit 1; }
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::$link"
  printf -- '- %s\n\n  %s\n\n' "$e" "$link" >> "$OUT"; n=$((n+1))
  echo "email #$i: $type link written"
done
[ "$i" -gt 0 ] || { echo "FAIL: PARTNER_EMAILS is empty"; exit 1; }
echo "$n" > "$OUT.count"
echo "links written: $n of $i"
