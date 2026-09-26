#!/usr/bin/env bash
# فحص قراءة فقط لحاوية ملفات المهام على مشروع حيّ (الشريحة 2ب، D27-5): موجودة، خاصة، 50MB، الصيغ الست بلا SVG،
# وبلا دخول لا يُقرأ منها شيء. لا يرفع ولا يحذف شيئًا. env: SUPABASE_URL SERVICE_KEY PUBLIC_KEY
set -uo pipefail
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
c=$(curl -s -o "$T/b.json" -w '%{http_code}' "$SUPABASE_URL/storage/v1/bucket/task-files" -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY")
if [ "$c" = 200 ] && jq -e '.public == false and .file_size_limit == 52428800
     and ((.allowed_mime_types // []) as $m | ["application/pdf","image/jpeg","image/png","image/webp","video/mp4","application/zip"] | all(. as $x | $m | index($x)))
     and ((.allowed_mime_types // []) | index("image/svg+xml") | not)' "$T/b.json" >/dev/null; then
  echo "ok   bucket task-files: private, 50MB, 6 types, no svg"
else echo "FAIL bucket task-files ($c)"; bad=1; fi
c=$(curl -s -o /dev/null -w '%{http_code}' "$SUPABASE_URL/storage/v1/object/public/task-files/t1/probe.pdf")
[ "$c" != 200 ] && echo "ok   no public URL ($c)" || { echo "FAIL public URL answered 200"; bad=1; }
c=$(curl -s -o "$T/l.json" -w '%{http_code}' -X POST "$SUPABASE_URL/storage/v1/object/list/task-files" -H "apikey: $PUBLIC_KEY" -H 'content-type: application/json' -d '{"prefix":"","limit":5}')
{ [ "$c" != 200 ] || jq -e 'length == 0' "$T/l.json" >/dev/null; } && echo "ok   anonymous listing shows nothing ($c)" || { echo "FAIL anonymous listing"; bad=1; }
[ $bad -eq 0 ] && echo "PASS storage check" || { echo "FAIL storage check"; exit 1; }
