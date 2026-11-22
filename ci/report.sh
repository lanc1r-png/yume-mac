#!/bin/bash
# Собирает компактный отчёт из build.log и кладёт его в ветку ci-logs (читается без доступа к Actions).
set -u
BRANCH_NAME="${GITHUB_REF_NAME//\//_}"
{
  echo "# commit ${GITHUB_SHA} branch ${GITHUB_REF_NAME} result ${1:-?}"
  echo "## errors"
  grep -E "\.swift:[0-9]+:[0-9]+: error:|error: " build.log | sed "s#${GITHUB_WORKSPACE}/##" | awk '!s[$0]++' | head -400
  echo "## warnings"
  grep -E "\.swift:[0-9]+:[0-9]+: warning:" build.log | sed "s#${GITHUB_WORKSPACE}/##" | awk '!s[$0]++' | head -200
  echo "## tail"
  tail -40 build.log
} > report.txt
git config --global user.email "ci@users.noreply.github.com"
git config --global user.name "ci"
REPO="https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
rm -rf /tmp/cilogs
if git ls-remote --exit-code --heads "$REPO" ci-logs >/dev/null 2>&1; then
  git clone --depth 1 --branch ci-logs "$REPO" /tmp/cilogs
else
  mkdir /tmp/cilogs && cd /tmp/cilogs && git init -q -b ci-logs && git remote add origin "$REPO"
fi
cd /tmp/cilogs
cp "${GITHUB_WORKSPACE}/report.txt" "${BRANCH_NAME}.txt"
git add -A && git commit -q -m "report ${GITHUB_SHA::7} ${BRANCH_NAME}" || true
git push -q origin ci-logs || (git pull -q --rebase origin ci-logs && git push -q origin ci-logs) || true
