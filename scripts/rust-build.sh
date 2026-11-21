#!/bin/bash
# In-container build of a Rust program for the box (static, MIPS32 R1), invoked by the Makefile.
#
# Usage: rust-build.sh <crate dir> <binary>[,<binary>...] [cargo args...]
#   e.g. rust-build.sh /src/backend maison-backend --no-default-features
#        rust-build.sh /src clapier,garenne-ctl -p clapier
# Output: /output/<binary> for each, stripped.
#
# mipsel-unknown-linux-musl is Tier 3 (no prebuilt std -> nightly + build-std) AND its stock spec
# emits MIPS32 R2 code, which the BMIPS4380 rejects with "Illegal instruction". So: dump the stock
# target spec, downgrade cpu to mips32 (R1, keeping the fpxx hard-float ABI, which matches the
# Bootlin userland), and link through the Bootlin musl gcc instead of rustc's self-contained crt.
#
# MIPS32 has no 64-bit atomics, and crates use AtomicU64 freely (tower-http, matter-*): the spec
# says 64 bits anyway, LLVM lowers them to __atomic_*_8 calls, and the toolchain's libatomic.a
# answers them (with locks: correct on the two cores, slower, and these are never hot).
#
# A crate that links OpenSSL (`openssl` with `vendored`): openssl-src knows no custom triple, so
# OpenSSL is built here for linux-mips32 (the Makefile's OPENSSL_VERSION) and handed to
# openssl-sys.
#
# Sized for the NAND: opt-level s, fat LTO, one codegen unit, panic abort, symbols stripped
# (maison-backend: 27 MB -> 12 MB), whatever the crate's own release profile says.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

CRATE="${1:?crate dir}"; BINS="${2:?binary name(s)}"; shift 2
IFS=, read -r -a BIN_LIST <<< "$BINS"
BIN_ARGS=()
for b in "${BIN_LIST[@]}"; do BIN_ARGS+=(--bin "$b"); done

CROSS="$(cat /opt/cross-prefix)"
TRIPLE=mipsel-airties-linux-musl
SPEC=/tmp/$TRIPLE.json
TARGET_DIR=/cargo-target/${BIN_LIST[0]}

# The nightly PINNED in the builder image: a bare `+nightly` would pull the floating channel
TOOLCHAIN="$(rustup toolchain list | awk '{print $1}' | grep '^nightly' | head -1)"
echo "$BINS: static Rust, MIPS32 R1 ($CROSS, $TOOLCHAIN)"

rustc "+$TOOLCHAIN" -Z unstable-options --print target-spec-json \
    --target mipsel-unknown-linux-musl > "$SPEC.orig"
python3 - "$SPEC" "$CROSS" << 'PYEOF'
import json, sys
spec = json.load(open(sys.argv[1] + ".orig"))
spec["cpu"] = "mips32"
spec["features"] = "+mips32,+fpxx,+nooddspreg"
spec["linker"] = sys.argv[2] + "-gcc"
spec["linker-flavor"] = "gnu-cc"
spec["link-self-contained"] = {"components": []}
spec["crt-static-default"] = True  # rootfs has no shared libs at all
spec["max-atomic-width"] = 64      # libatomic.a, see above
spec.pop("is-builtin", None)
json.dump(spec, open(sys.argv[1], "w"), indent=2)
print("[*] target spec: cpu=%s features=%s" % (spec["cpu"], spec["features"]))
PYEOF

# The musl spec hardcodes -lunwind; without rustc's self-contained libs the Bootlin toolchain
# has no libunwind.a. Its libgcc_eh.a exports the same _Unwind_* symbols (barely used anyway:
# panic=abort), so shim it. libatomic by its path: -latomic would find the .so first.
SHIM=/tmp/unwind-shim
mkdir -p "$SHIM"
cp "$(dirname "$("${CROSS}-gcc" -print-libgcc-file-name)")/libgcc_eh.a" "$SHIM/libunwind.a"
LIBATOMIC="$("${CROSS}-gcc" -print-file-name=libatomic.a)"
export RUSTFLAGS="-C target-feature=+crt-static -L $SHIM -C link-arg=$LIBATOMIC"
export TARGET_CC="${CROSS}-gcc" TARGET_AR="${CROSS}-ar" TARGET_RANLIB="${CROSS}-ranlib"
export CARGO_PROFILE_RELEASE_OPT_LEVEL=s CARGO_PROFILE_RELEASE_LTO=fat \
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 CARGO_PROFILE_RELEASE_PANIC=abort \
    CARGO_PROFILE_RELEASE_STRIP=symbols

cd "$CRATE"
cargo "+$TOOLCHAIN" fetch --locked >/dev/null

if cargo "+$TOOLCHAIN" tree --locked -e normal -i openssl-src >/dev/null 2>&1; then
    # The image's one OpenSSL (OPENSSL_VERSION, the Makefile's pin; mosquitto's too), not the 3.x
    # the crate vendors: openssl-sys binds OpenSSL 4 but its `vendored` feature still asks for
    # openssl-src 300.x
    OPENSSL_VERSION="${OPENSSL_VERSION:?OPENSSL_VERSION not set}"
    OSSL=/cargo-target/openssl-$OPENSSL_VERSION
    if [ ! -f "$OSSL/lib/libssl.a" ]; then
        echo "[*] OpenSSL ${OPENSSL_VERSION} for linux-mips32"
        fetch "openssl-${OPENSSL_VERSION}.tar.gz" \
            "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
        rm -rf /tmp/ossl-src && mkdir -p /tmp/ossl-src && tar xzf "/dl/openssl-${OPENSSL_VERSION}.tar.gz" -C /tmp/ossl-src
        build_openssl "/tmp/ossl-src/openssl-${OPENSSL_VERSION}" "$OSSL"
        rm -rf /tmp/ossl-src
    fi
    export OPENSSL_NO_VENDOR=1 OPENSSL_STATIC=1 OPENSSL_DIR="$OSSL"
fi

cargo "+$TOOLCHAIN" build --release --locked \
    -Z build-std=std,panic_abort \
    -Z json-target-spec \
    --target "$SPEC" \
    --target-dir "$TARGET_DIR" \
    "${BIN_ARGS[@]}" "$@" \
    2>&1 | grep -vE '^\s+(Compiling|Downloaded|Downloading) ' | tail -20

for BIN in "${BIN_LIST[@]}"; do
    OUT="$TARGET_DIR/$TRIPLE/release/$BIN"
    [ -f "$OUT" ] || { echo "!!! BUILD FAILED: $BIN !!!"; exit 1; }
    file "$OUT" | grep -q 'statically linked' || \
        { echo "!!! $BIN is not static: the rootfs has no shared libs !!!"; file "$OUT"; exit 1; }
    # Not one MIPS32 R2 instruction: the BMIPS4380 traps on them
    if "${CROSS}-objdump" -d "$OUT" | grep -qE $'\t(ext|ins|seb|seh|wsbh|rotr|rotrv|mfhc1|mthc1|di|ei)\t'; then
        echo "!!! $BIN holds MIPS32 R2 instructions !!!"; exit 1
    fi
    cp "$OUT" "/output/$BIN"
    ls -l "/output/$BIN"
done
