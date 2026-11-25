#!/usr/bin/env bash

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d /tmp/setup-toolchain.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

fake_bin="$tmp/fake-bin"
runner_temp="$tmp/runner-temp"
github_path="$tmp/github-path"
mkdir -p "$fake_bin" "$runner_temp"

cat >"$fake_bin/rustup" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1 $2 $3" = "target add wasm32-unknown-unknown" ]; then
  printf '%s\n' wasm32-unknown-unknown >"$RUNNER_TEMP/installed-targets"
elif [ "$1 $2 $3" = "target list --installed" ]; then
  cat "$RUNNER_TEMP/installed-targets"
else
  exit 2
fi
EOF

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output" ]; then
    printf 'verified archive fixture\n' >"$2"
    exit 0
  fi
  shift
done
exit 2
EOF

cat >"$fake_bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
expected='2ab8d548fd5ed9cda50906f61fd8654204e7893bd52ebbfd90533862b7d71ee1'
read -r digest archive
[ "$1" = "--check" ]
[ "$digest" = "$expected" ]
[ -f "$archive" ]
printf '%s: OK\n' "$archive"
EOF

cat >"$fake_bin/tar" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--directory" ]; then
    directory="$2"
    break
  fi
  shift
done
cat >"$directory/trunk" <<'TRUNK'
#!/usr/bin/env bash
printf '%s\n' 'trunk 0.22.1'
TRUNK
chmod +x "$directory/trunk"
EOF

chmod +x "$fake_bin"/*

output="$tmp/output"
PATH="$fake_bin:$PATH" RUNNER_TEMP="$runner_temp" GITHUB_PATH="$github_path" \
  TOOLCHAIN_PROFILE=rust-wasm-trunk-0.22.1 \
  bash "$here/setup-toolchain.sh" >"$output"

grep -Fx 'wasm32-unknown-unknown' "$output" >/dev/null
grep -F ': OK' "$output" >/dev/null
grep -Fx 'trunk 0.22.1' "$output" >/dev/null
grep -Fx "$runner_temp/trunk-0.22.1-bin" "$github_path" >/dev/null

if PATH="$fake_bin:$PATH" RUNNER_TEMP="$runner_temp" GITHUB_PATH="$github_path" \
  TOOLCHAIN_PROFILE=caller-controlled bash "$here/setup-toolchain.sh" >/dev/null 2>&1; then
  echo "unsupported profile unexpectedly succeeded" >&2
  exit 1
fi

echo "PASS: pinned Trunk checksum, version, WASM target, PATH, and profile allowlist"
