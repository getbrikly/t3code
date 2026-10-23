#!/usr/bin/env bash
# Rebase the fork onto upstream main (what Nightly ships from) and build a
# fresh "T3 Code (Alpha).app" for local install.
#
# Usage: scripts/update-alpha.sh [--no-rebase] [--no-remote] [--push]
#   --no-rebase  build the current checkout as-is
#   --no-remote  skip installing the server on SSH hosts
#   --push       force-push the rebased main to origin afterwards
#
# Also installs the matching server on each SSH host in $T3_FORK_REMOTES
# (space-separated, default "cloud-machine") via scripts/update-remote.sh.
#
# Builds only the zip target (skips the slow DMG step), then unpacks it to
# release/alpha/ and reveals the .app in Finder. Installing it into
# /Applications is left to you.
set -euo pipefail

rebase=1
remote=1
push=0
for arg in "$@"; do
  case "$arg" in
    --no-rebase) rebase=0 ;;
    --no-remote) remote=0 ;;
    --push) push=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

if [[ "$(git branch --show-current)" != "main" ]]; then
  echo "error: check out main first" >&2
  exit 1
fi
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "error: working tree has uncommitted changes" >&2
  exit 1
fi

if (( rebase )); then
  git fetch upstream --quiet
  behind="$(git rev-list --count main..upstream/main)"
  echo "==> main is $behind commits behind upstream/main"
  if (( behind > 0 )); then
    backup="backup/main-pre-rebase-$(date +%Y%m%d)"
    git branch -f "$backup" main
    echo "==> backup ref: $backup"
    if ! git rebase upstream/main; then
      echo "error: rebase conflicted. Resolve it (or 'git rebase --abort'), then rerun with --no-rebase" >&2
      exit 1
    fi
  fi
  git log --oneline upstream/main..main
fi

echo "==> pnpm install"
# confirmModulesPurge: a Node or pnpm bump otherwise stops on a TTY prompt.
pnpm install --frozen-lockfile --config.confirmModulesPurge=false

echo "==> building app (zip target)"
pnpm exec node scripts/build-desktop-artifact.ts --platform mac --target zip --arch arm64

zip_path="$(ls -t release/T3-Code-*-arm64.zip | head -n 1)"
rm -rf release/alpha
mkdir -p release/alpha
ditto -x -k "$zip_path" release/alpha
app_path="$(find release/alpha -maxdepth 1 -name '*.app' | head -n 1)"
echo "==> built: $app_path (from $zip_path)"

if (( remote )); then
  # shellcheck disable=SC2086 # word-split the host list
  scripts/update-remote.sh ${T3_FORK_REMOTES:-cloud-machine}
fi

if (( push )); then
  git push --force-with-lease origin main
fi

open -R "$app_path"
echo "Quit T3 Code (Alpha), then drag the app into /Applications to replace it."
