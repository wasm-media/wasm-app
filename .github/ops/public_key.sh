#!/usr/bin/env bash
# يختار المفتاح العام للمتصفح من مخرج `supabase projects api-keys -o json`، ويرفض أي مفتاح سري (I6، I12).
# يقبل: JWT قديم دوره anon، أو sb_publishable_. يطبع المفتاح وحده على stdout، والأخطاء على stderr.
# الاستعمال: public_key.sh <keys.json>
set -euo pipefail
K=$(jq -r '([.[] | select(.name == "anon" and (.api_key | startswith("eyJ")))][0].api_key)
         // ([.[] | select(.type == "publishable")][0].api_key) // empty' "$1")
[ -n "$K" ] || { echo "FAIL: no public key in api-keys output" >&2; exit 1; }
case "$K" in
  sb_publishable_*) ;;
  sb_*) echo "FAIL: refused a non-publishable sb_ key" >&2; exit 1 ;;
  eyJ*)
    role=$(python3 -c 'import sys,json,base64; p=sys.argv[1].split(".")[1]; print(json.loads(base64.urlsafe_b64decode(p+"="*(-len(p)%4))).get("role",""))' "$K" 2>/dev/null || true)
    [ "$role" = anon ] || { echo "FAIL: JWT key role is '$role', not anon" >&2; exit 1; } ;;
  *) echo "FAIL: unknown key format" >&2; exit 1 ;;
esac
printf '%s' "$K"
