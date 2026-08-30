# CSSH.xcframework — provenance & reproducible build

## What this is

A static, universal (arm64 + x86_64) build of **libssh2** with its crypto backend,
wrapped as an xcframework and consumed by the vendored `Sources/Shout` bindings.

Current embedded version: **libssh2 1.10.0** (`LIBSSH2_VERSION` in
`macos-arm64_x86_64/Headers/libssh2.h`; fat archive verified with
`lipo -info macos-arm64_x86_64/libssh2.a`). The 1.10.0 binary predates this
repository's rewrite and its exact original build flags are not recorded — which is
precisely why this file now exists. **An upgrade to the current libssh2 release via
the script below is planned and tracked; treat 1.10.0 as legacy until then.**

## Reproducible build

Requirements: Xcode command-line tools, `curl`, ~10 minutes.

```bash
#!/bin/bash
set -euo pipefail
LIBSSH2_VERSION=1.11.1          # https://libssh2.org — pick the current release
OPENSSL_VERSION=3.5.1           # https://openssl-library.org
MACOS_MIN=14.0
WORK=$(mktemp -d)

build_openssl() { # $1 = arch
  local arch=$1 prefix="$WORK/openssl-$arch"
  tar xf "$WORK/openssl.tar.gz" -C "$WORK"
  pushd "$WORK/openssl-$OPENSSL_VERSION"
  ./Configure "darwin64-$arch-cc" no-shared no-tests \
      --prefix="$prefix" -mmacosx-version-min=$MACOS_MIN
  make -j"$(sysctl -n hw.ncpu)" && make install_sw
  popd && rm -rf "$WORK/openssl-$OPENSSL_VERSION"
}

build_libssh2() { # $1 = arch
  local arch=$1 prefix="$WORK/libssh2-$arch"
  tar xf "$WORK/libssh2.tar.gz" -C "$WORK"
  pushd "$WORK/libssh2-$LIBSSH2_VERSION"
  CFLAGS="-arch $arch -mmacosx-version-min=$MACOS_MIN" \
  ./configure --host="$arch-apple-darwin" --prefix="$prefix" \
      --with-crypto=openssl --with-libssl-prefix="$WORK/openssl-$arch" \
      --disable-shared --disable-examples-build
  make -j"$(sysctl -n hw.ncpu)" && make install
  popd && rm -rf "$WORK/libssh2-$LIBSSH2_VERSION"
}

curl -Lo "$WORK/libssh2.tar.gz"  "https://libssh2.org/download/libssh2-$LIBSSH2_VERSION.tar.gz"
curl -Lo "$WORK/openssl.tar.gz"  "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"

for arch in arm64 x86_64; do build_openssl "$arch"; build_libssh2 "$arch"; done

# libssh2 + its statically-linked crypto must travel together:
for arch in arm64 x86_64; do
  libtool -static -o "$WORK/combined-$arch.a" \
      "$WORK/libssh2-$arch/lib/libssh2.a" \
      "$WORK/openssl-$arch/lib/libssl.a" "$WORK/openssl-$arch/lib/libcrypto.a"
done
lipo -create "$WORK/combined-arm64.a" "$WORK/combined-x86_64.a" \
     -output macos-arm64_x86_64/libssh2.a
cp "$WORK/libssh2-arm64/include/"*.h macos-arm64_x86_64/Headers/
```

`Info.plist` and `Headers/module.modulemap` stay as-is. After replacing the binary:

1. `swift build --build-tests && swift test` (unit + `SSHIntegrationTests` against a
   local sshd — see `Tests/SiftLibTests/SSHIntegrationTests.swift` for the
   `SIFT_TEST_SSH_*` environment).
2. Verify the full auth matrix: password, ssh-agent, RSA, ECDSA, Ed25519 (with and
   without a `.pub` sidecar), plus host-key verification in `strict` and `acceptNew`
   against a non-22 port.
3. Record the new versions in this file.

## Why vendored at all

`Sources/Shout` calls libssh2's C API directly (sessions, channels, SFTP, agent,
known-hosts). A system libssh2 is not guaranteed on macOS, and Homebrew's dylib
would add a runtime dependency for every node operator — a static universal archive
keeps `Sift` a single self-contained binary.
