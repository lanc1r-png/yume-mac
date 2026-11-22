#!/bin/bash
# Запускает собранное приложение в нескольких режимах, снимает экран, кладёт снимки и крэш-логи в ветку ci-logs.
APP=$(find build/Build/Products -maxdepth 2 -name "*.app" | head -1)
[ -z "$APP" ] && exit 0
OUT=/tmp/shots; rm -rf $OUT; mkdir -p $OUT
run() { # name, args...
  NAME="$1"; shift
  pkill -x Yume 2>/dev/null; sleep 1
  "$APP/Contents/MacOS/Yume" "$@" > "$OUT/$NAME.log" 2>&1 &
  sleep 18
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
python3 - <<'PY' > $OUT/crashes_body.txt
import glob, json, os
files = sorted(glob.glob(os.path.expanduser('~/Library/Logs/DiagnosticReports/*Yume*.ips')))[:1]
for f in files:
    raw = open(f).read().split('\n', 1)[1]
    d = json.loads(raw)
    print('exception:', d.get('exception'), d.get('termination'), d.get('asi'))
    imgs = d.get('usedImages', [])
    def fr(frames, n):
        for x in frames[:n]:
            im = imgs[x.get('imageIndex', 0)].get('name', '?') if x.get('imageIndex', 0) < len(imgs) else '?'
            print('  ', im, x.get('symbol'), x.get('imageOffset'))
    print('lastExceptionBacktrace:')
    fr(d.get('lastExceptionBacktrace', []), 30)
    t = d['threads'][d.get('faultingThread', 0)]
    print('faulting thread frames:')
    fr(t.get('frames', []), 40)
PY
BRANCH_NAME="${GITHUB_REF_NAME//\//_}"
git config --global user.email "ci@users.noreply.github.com"; git config --global user.name "ci"
REPO="https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
rm -rf /tmp/cilogs2
git clone --depth 1 --branch ci-logs "$REPO" /tmp/cilogs2 || exit 0
cd /tmp/cilogs2
rm -rf "shots/$BRANCH_NAME"; mkdir -p "shots/$BRANCH_NAME"
# уменьшаем снимки, чтобы ветка не раздувалась
for f in $OUT/*.png; do sips -Z 1400 "$f" --out "shots/$BRANCH_NAME/$(basename $f)" >/dev/null 2>&1 || cp "$f" "shots/$BRANCH_NAME/"; done
for f in $OUT/*.log; do head -80 "$f" > "shots/$BRANCH_NAME/$(basename $f)"; done
cp $OUT/status.txt $OUT/crashes.txt $OUT/crashes_body.txt "shots/$BRANCH_NAME/" 2>/dev/null
git add -A && git commit -q -m "shots ${GITHUB_SHA::7} ${BRANCH_NAME}" || true
git push -q origin ci-logs || (git pull -q --rebase origin ci-logs && git push -q origin ci-logs) || true
