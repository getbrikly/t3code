#!/usr/bin/env bash
# Install this checkout's server on a Linux x64 SSH host the desktop app
# connects to.
#
# Usage: scripts/update-remote.sh <ssh-host>...
#
# The desktop app never sends its own server over SSH: the remote launcher
# downloads upstream's release archive for the app's version into
# ~/.t3/runtime/versions/<version>/ and reuses it while .install-complete
# matches. So the fork's server-side changes only reach a remote if we
# pre-install our own archive under that same version.
#
# Expects apps/server/dist/client from a prior desktop build (update-alpha.sh
# runs this after building the app).
set -euo pipefail

if (( $# == 0 )); then
  echo "usage: $0 <ssh-host>..." >&2
  exit 2
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

version="$(node -p 'require("./apps/server/package.json").version')"
work_dir="release/remote"
archive="$work_dir/t3-$version-linux-x64.tar.gz"
monitor_dir="$work_dir/resource-monitor"
mkdir -p "$work_dir/bin"

echo "==> building linux-x64 server $version"
pnpm exec node apps/server/scripts/cli.ts build-exe --target linux-x64

# The resource monitor is a Rust binary with no fork changes, and neither this
# Mac nor the hosts have a Linux cross toolchain: reuse the one upstream's
# archive installed on the first host.
if [[ ! -x "$monitor_dir/linux-x64/t3-resource-monitor" ]]; then
  mkdir -p "$monitor_dir/linux-x64"
  scp -q "$1:.t3/runtime/versions/*/resource-monitor/linux-x64/t3-resource-monitor" \
    "$monitor_dir/linux-x64/"
fi

# build-cli-archive passes GNU tar's --hard-dereference for Linux archives (the
# npm registry rejects hard links). macOS bsdtar lacks it and nothing here is
# published to npm, so drop the flag.
cat >"$work_dir/bin/tar" <<'SH'
#!/usr/bin/env bash
args=(); for a in "$@"; do [[ $a == --hard-dereference ]] || args+=("$a"); done
exec /usr/bin/tar "${args[@]}"
SH
chmod +x "$work_dir/bin/tar"
PATH="$repo_root/$work_dir/bin:$PATH" pnpm exec node scripts/build-cli-archive.ts \
  --platform linux --arch x64 --version "$version" \
  --resource-monitor-dir "$monitor_dir" --output-dir "$work_dir"

for host in "$@"; do
  echo "==> installing on $host"
  remote_archive=".t3/runtime/fork-t3-$version-linux-x64.tar.gz"
  ssh "$host" 'mkdir -p ~/.t3/runtime/versions'
  scp -q "$archive" "$host:$remote_archive"
  ssh "$host" sh -s -- "$version" "$remote_archive" <<'SH'
set -eu
version="$1"
archive="$HOME/$2"
versions="$HOME/.t3/runtime/versions"
staging="$(mktemp -d "$versions/.staging-XXXXXX")"
tar -xzf "$archive" -C "$staging" --strip-components=1
rm -f "$archive"
"$staging/t3" --version >/dev/null
printf '%s\n' "$version" >"$staging/.install-complete"

# A same-version rebuild does not change the launcher's runner, so it would
# keep reusing a server already running from this version. Stop only the
# servers the launcher recorded at spawn; the app relaunches on reconnect.
for state in "$HOME"/.t3/ssh-launch/*/; do
  [ "$(cat "$state/managed" 2>/dev/null)" = managed ] || continue
  pid="$(cat "$state/pid" 2>/dev/null)" || continue
  exe="$(readlink "/proc/$pid/exe" 2>/dev/null)" || continue
  case "$exe" in
    "$versions/$version/"*)
      kill "$pid"
      i=0
      while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do i=$((i + 1)); sleep 0.2; done
      echo "stopped server $pid (reconnect the app to start the new one)"
      ;;
  esac
done

rm -rf "$versions/$version"
mv "$staging" "$versions/$version"

# Prune other versions unless a server is still running from one.
in_use=""
for state in "$HOME"/.t3/ssh-launch/*/; do
  pid="$(cat "$state/pid" 2>/dev/null)" || continue
  in_use="$in_use $(readlink "/proc/$pid/exe" 2>/dev/null || true)"
done
for dir in "$versions"/*/; do
  dir="${dir%/}"
  [ "$dir" = "$versions/$version" ] && continue
  case "$in_use" in *"$dir/"*) echo "kept $dir (in use)"; continue ;; esac
  rm -rf "$dir"
done
echo "installed $version: $("$versions/$version/t3" --version)"
SH
done
