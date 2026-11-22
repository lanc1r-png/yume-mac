#!/bin/bash
# Запускает собранное приложение в нескольких режимах, снимает экран, кладёт снимки и крэш-логи в ветку ci-logs.
APP=$(find build/Build/Products -maxdepth 2 -name "*.app" | head -1)
[ -z "$APP" ] && exit 0
OUT=/tmp/shots; rm -rf $OUT; mkdir -p $OUT
run() { # name, args...
  NAME="$1"; shift
  pkill -x Yume 2>/dev/null; sleep 1
  open -n "$APP" --args "$@"
  sleep 22
  if pgrep -x Yume >/dev/null; then echo "$NAME: alive" >> $OUT/status.txt; else echo "$NAME: DEAD" >> $OUT/status.txt; fi
  screencapture -x "$OUT/$NAME.png" 2>>$OUT/status.txt || true
}
run home -set.platform anime -debug.tab 0
run catalog -set.platform anime -debug.tab 1
run favorites -set.platform anime -debug.tab 2
run settings -set.platform anime -debug.tab 4
run manga_home -set.platform manga -debug.tab 0
run kino_home -set.platform kino -debug.tab 0
pkill -x Yume 2>/dev/null
ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -i yume > $OUT/crashes.txt
for f in $(ls ~/Library/Logs/DiagnosticReports/*Yume* 2>/dev/null | head -2); do head -80 "$f" >> $OUT/crashes_body.txt; done
BRANCH_NAME="${GITHUB_REF_NAME//\//_}"
git config --global user.email "ci@users.noreply.github.com"; git config --global user.name "ci"
REPO="https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
rm -rf /tmp/cilogs2
git clone --depth 1 --branch ci-logs "$REPO" /tmp/cilogs2 || exit 0
cd /tmp/cilogs2
rm -rf "shots/$BRANCH_NAME"; mkdir -p "shots/$BRANCH_NAME"
# уменьшаем снимки, чтобы ветка не раздувалась
for f in $OUT/*.png; do sips -Z 1400 "$f" --out "shots/$BRANCH_NAME/$(basename $f)" >/dev/null 2>&1 || cp "$f" "shots/$BRANCH_NAME/"; done
cp $OUT/status.txt $OUT/crashes.txt $OUT/crashes_body.txt "shots/$BRANCH_NAME/" 2>/dev/null
git add -A && git commit -q -m "shots ${GITHUB_SHA::7} ${BRANCH_NAME}" || true
git push -q origin ci-logs || (git pull -q --rebase origin ci-logs && git push -q origin ci-logs) || true
