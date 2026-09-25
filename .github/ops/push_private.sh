#!/usr/bin/env bash
# يرفع ملفات إلى المستودع الخاص wasm-media/wasm-app-backups بمفتاح نشر (deploy key) يكتبه عيسى سرًّا —
# Claude لا يراه (I12). مفتاح مضيف GitHub يُطابق ببصمته المنشورة قبل أي اتصال. التاريخ يُحفظ في git (§5.5).
# الاستعمال: push_private.sh "<رسالة>" <ملف-مصدر>:<مسار-في-المستودع> ...
# env: BACKUP_DEPLOY_KEY · [REMOTE] (للتجربة المحلية فقط: مسار مستودع bare بدل GitHub)
set -euo pipefail
MSG=$1; shift
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
REMOTE=${REMOTE:-git@github.com:wasm-media/wasm-app-backups.git}
if [[ "$REMOTE" == git@github.com:* ]]; then
  [ -n "${BACKUP_DEPLOY_KEY:-}" ] || { echo "FAIL: BACKUP_DEPLOY_KEY is not set in this environment"; exit 1; }
  mkdir -m 700 "$W/ssh"; printf '%s\n' "$BACKUP_DEPLOY_KEY" > "$W/ssh/key"; chmod 600 "$W/ssh/key"
  ssh-keyscan -t ed25519 github.com 2>/dev/null > "$W/ssh/known_hosts"
  fp=$(ssh-keygen -lf "$W/ssh/known_hosts" | awk '{print $2}')
  [ "$fp" = "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU" ] || { echo "FAIL: github.com host key fingerprint mismatch ($fp)"; exit 1; }
  export GIT_SSH_COMMAND="ssh -i $W/ssh/key -o IdentitiesOnly=yes -o UserKnownHostsFile=$W/ssh/known_hosts -o StrictHostKeyChecking=yes"
fi
git clone -q --depth 1 "$REMOTE" "$W/repo" 2>"$W/clone.err" || { echo "FAIL: clone private repo"; grep -v '^warning' "$W/clone.err" | head -3; exit 1; }
for pair in "$@"; do
  src=${pair%%:*}; dst=${pair#*:}
  [ -s "$src" ] || { echo "FAIL: missing or empty $src"; exit 1; }
  mkdir -p "$W/repo/$(dirname "$dst")"; cp "$src" "$W/repo/$dst"
done
cd "$W/repo"; git add -A
if git diff --cached --quiet; then echo "nothing new to push"; exit 0; fi
git -c user.name=wasm-ci -c user.email=ci@wasm-media.invalid commit -qm "$MSG"
git push -q origin HEAD:main
echo "pushed: $(git rev-parse --short HEAD) ($# files)"
