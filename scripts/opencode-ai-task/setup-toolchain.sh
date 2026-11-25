#!/usr/bin/env bash

# Install an explicitly selected, centrally owned toolchain profile. This runs
# only in the read-only implementation job and never evaluates setup code from
# the target repository.

set -euo pipefail

profile="${TOOLCHAIN_PROFILE:?TOOLCHAIN_PROFILE is required}"

case "${profile}" in
  rudiment-web)
    trunk_version=0.22.1
    trunk_sha256=2ab8d548fd5ed9cda50906f61fd8654204e7893bd52ebbfd90533862b7d71ee1
    archive="${RUNNER_TEMP:?RUNNER_TEMP is required}/trunk-${trunk_version}.tar.gz"
    bin_dir="${RUNNER_TEMP}/trunk-${trunk_version}-bin"

    rustup target add wasm32-unknown-unknown
    rustup target list --installed | grep -Fx 'wasm32-unknown-unknown'

    curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
      "https://github.com/trunk-rs/trunk/releases/download/v${trunk_version}/trunk-x86_64-unknown-linux-gnu.tar.gz" \
      --output "${archive}"
    echo "${trunk_sha256}  ${archive}" | sha256sum --check

    mkdir -p "${bin_dir}"
    tar --extract --gzip --file "${archive}" --directory "${bin_dir}" trunk
    echo "${bin_dir}" >>"${GITHUB_PATH:?GITHUB_PATH is required}"
    PATH="${bin_dir}:${PATH}"
    export PATH

    [ "$(trunk --version)" = "trunk ${trunk_version}" ] || {
      echo "::error::Unexpected Trunk version: $(trunk --version)"
      exit 1
    }
    trunk --version
    ;;
  *)
    echo "::error::Unsupported toolchain profile: ${profile}"
    exit 1
    ;;
esac
