#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS dependency setup must run on a Mac.' >&2; exit 1; }
: "${OPENVPN_BUILD_ENV_FILE:?Run node install.mjs from the repository root.}"
: "${OPENVPN_BUILD_NODE:?Run node install.mjs from the repository root.}"
: "${OPENVPN_BUILD_ARCH:?Run node install.mjs from the repository root.}"

if ! xcrun --find clang >/dev/null 2>&1; then
  xcode-select --install || true
  echo 'Complete the Xcode Command Line Tools installation, then rerun node install.mjs.' >&2
  exit 1
fi

case "$OPENVPN_BUILD_ARCH" in
  arm64) BREW_DEFAULT=/opt/homebrew/bin/brew; RUST_TARGET=aarch64-apple-darwin ;;
  x64) BREW_DEFAULT=/usr/local/bin/brew; RUST_TARGET=x86_64-apple-darwin ;;
  *) echo 'Unsupported Mac architecture.' >&2; exit 1 ;;
esac
if [[ -x "$BREW_DEFAULT" ]]; then
  BREW="$BREW_DEFAULT"
elif command -v brew >/dev/null 2>&1; then
  BREW="$(command -v brew)"
else
  echo 'Homebrew is required. Install it from https://brew.sh, then rerun node install.mjs.' >&2
  exit 1
fi
BREW_PREFIX="$("$BREW" --prefix)"
if [[ "$OPENVPN_BUILD_ARCH" == arm64 && "$BREW_PREFIX" == /usr/local ]] ||
   [[ "$OPENVPN_BUILD_ARCH" == x64 && "$BREW_PREFIX" == /opt/homebrew ]]; then
  echo 'Node.js and Homebrew use different architectures. Run both in the same native or Rosetta environment.' >&2
  exit 1
fi
export PATH="$BREW_PREFIX/bin:$PATH"
command -v npm >/dev/null || { echo 'Install the full Node.js 22+ distribution, including npm.' >&2; exit 1; }

missing=()
for formula in git cmake asio jsoncpp lz4 openssl@3 pkg-config xxhash; do
  if ! "$BREW" list --versions "$formula" >/dev/null 2>&1; then missing+=("$formula"); fi
done
if [[ ${#missing[@]} -gt 0 ]]; then
  HOMEBREW_NO_AUTO_UPDATE=1 "$BREW" install "${missing[@]}"
fi

export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
if ! command -v rustup >/dev/null 2>&1; then
  RUSTUP_SCRIPT="${OPENVPN_BUILD_ENV_FILE%.json}-rustup.sh"
  trap 'rm -f "$RUSTUP_SCRIPT"' EXIT
  curl --proto '=https' --tlsv1.2 -fsS https://sh.rustup.rs -o "$RUSTUP_SCRIPT"
  sh "$RUSTUP_SCRIPT" -y --no-modify-path --profile minimal --default-toolchain none
fi
export RUSTUP_TOOLCHAIN="stable-$RUST_TARGET"
if ! rustup run "$RUSTUP_TOOLCHAIN" rustc --version >/dev/null 2>&1; then
  rustup toolchain install "$RUSTUP_TOOLCHAIN" --profile minimal
fi
rustup run "$RUSTUP_TOOLCHAIN" cargo --version
OPENSSL_PREFIX="$("$BREW" --prefix openssl@3)"
export CMAKE_PREFIX_PATH="$BREW_PREFIX:$OPENSSL_PREFIX${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export PKG_CONFIG_PATH="$OPENSSL_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
pkg-config --exists openssl

"$OPENVPN_BUILD_NODE" --input-type=module -e '
import fs from "node:fs";
const keys = ["PATH", "RUSTUP_TOOLCHAIN", "CMAKE_PREFIX_PATH", "PKG_CONFIG_PATH"];
fs.writeFileSync(process.env.OPENVPN_BUILD_ENV_FILE,
  JSON.stringify(Object.fromEntries(keys.map(key => [key, process.env[key]]))), { mode: 0o600 });
'
echo 'macOS build dependencies and library paths are ready.'
