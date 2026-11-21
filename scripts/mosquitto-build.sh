#!/bin/bash
# In-container Mosquitto build (static, musl, MIPS32 R1), invoked by `make mosquitto`.
# The broker alone: Maison's Meross plugs want one to boot (TLS, anonymous; the kernel lets only
# the plugs reach it, see rootfs/maison/usr/sbin/mosquitto-run). Its TLS is OpenSSL (the pinned
# release, lib.sh's build_openssl), its JSON cJSON (the broker requires it); no websockets, no
# HTTP API, no control topics, no plugins, no SQLite.
# Output: /output/mosquitto
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

MOSQUITTO_VERSION="${MOSQUITTO_VERSION:?MOSQUITTO_VERSION not set}"
OPENSSL_VERSION="${OPENSSL_VERSION:?OPENSSL_VERSION not set}"
CJSON_VERSION="${CJSON_VERSION:?CJSON_VERSION not set}"
CROSS="$(cat /opt/cross-prefix)"
DEPS=/tmp/mosq-deps

echo "Mosquitto ${MOSQUITTO_VERSION} (OpenSSL ${OPENSSL_VERSION}, cJSON ${CJSON_VERSION}): static, MIPS32 R1"

fetch "mosquitto-${MOSQUITTO_VERSION}.tar.gz" "https://mosquitto.org/files/source/mosquitto-${MOSQUITTO_VERSION}.tar.gz"
fetch "openssl-${OPENSSL_VERSION}.tar.gz" \
    "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
fetch "cJSON-${CJSON_VERSION}.tar.gz" "https://github.com/DaveGamble/cJSON/archive/refs/tags/v${CJSON_VERSION}.tar.gz"

BUILDDIR=/tmp/mosq
rm -rf "$BUILDDIR" "$DEPS"; mkdir -p "$BUILDDIR" "$DEPS/lib" "$DEPS/include/cjson"
for t in "mosquitto-${MOSQUITTO_VERSION}.tar.gz" "openssl-${OPENSSL_VERSION}.tar.gz" "cJSON-${CJSON_VERSION}.tar.gz"; do
    tar xzf "/dl/$t" -C "$BUILDDIR"
done

echo "[*] OpenSSL..."
build_openssl "$BUILDDIR/openssl-${OPENSSL_VERSION}" "$DEPS/openssl"

echo "[*] cJSON..."
(cd "$BUILDDIR/cJSON-${CJSON_VERSION}" \
    && "${CROSS}-gcc" -Os -c cJSON.c -o cJSON.o \
    && "${CROSS}-ar" rcs "$DEPS/lib/libcjson.a" cJSON.o \
    && cp cJSON.h "$DEPS/include/cjson/")

echo "[*] Mosquitto..."
cd "$BUILDDIR/mosquitto-${MOSQUITTO_VERSION}"
# OpenSSL's threads use 64-bit atomics, which MIPS32 lacks: the toolchain's libatomic answers
# them (as in rust-build.sh). Last on the broker's link line, after -lcrypto (a static link
# resolves left to right); the Makefile takes no extra library from outside.
# shellcheck disable=SC2016  # make's own $(...) and ${...}, literal
sed -i 's/^\t\${CROSS_COMPILE}\${CC} \${LOCAL_LDFLAGS} \$^ -o \$@ \$(LOCAL_LDADD)$/& -latomic/' src/Makefile
# shellcheck disable=SC2016
grep -q -- '-o \$@ \$(LOCAL_LDADD) -latomic$' src/Makefile || { echo "!! src/Makefile: the -latomic patch did not apply"; exit 1; }
OPTS=(WITH_STATIC_LIBRARIES=yes WITH_SHARED_LIBRARIES=no WITH_WEBSOCKETS=no WITH_HTTP_API=no
    WITH_CONTROL=no WITH_SQLITE=no WITH_DOCS=no WITH_SYSTEMD=no WITH_SRV=no WITH_EDITLINE=no
    WITH_GMOCK=no WITH_ARGON2=no WITH_BUNDLED_DEPS=yes WITH_TLS=yes WITH_EPOLL=yes)
make -j"$(nproc)" -C lib libmosquitto.a "${OPTS[@]}" CC="${CROSS}-gcc" AR="${CROSS}-ar" \
    CPPFLAGS="-I$DEPS/openssl/include -I$DEPS/include" CFLAGS="-Os -Wall -std=gnu99" >/dev/null
make -j"$(nproc)" -C libcommon libmosquitto_common.a "${OPTS[@]}" CC="${CROSS}-gcc" AR="${CROSS}-ar" \
    CPPFLAGS="-I$DEPS/openssl/include -I$DEPS/include" CFLAGS="-Os -Wall -std=gnu99" >/dev/null
make -j"$(nproc)" -C src mosquitto "${OPTS[@]}" CC="${CROSS}-gcc" AR="${CROSS}-ar" \
    CPPFLAGS="-I$DEPS/openssl/include -I$DEPS/include" CFLAGS="-Os -Wall -std=gnu99" \
    LDFLAGS="-static -L$DEPS/openssl/lib -L$DEPS/lib" > /output/mosquitto_build.log 2>&1 \
    || { grep -iE "undefined reference|cannot find|error" /output/mosquitto_build.log | sort -u | head -20; exit 1; }

[ -f src/mosquitto ] || { echo "!!! BUILD FAILED: src/mosquitto missing !!!"; exit 1; }
file src/mosquitto | grep -q 'statically linked' || { echo "!!! mosquitto is not static !!!"; file src/mosquitto; exit 1; }
cp src/mosquitto /output/mosquitto
"${CROSS}-strip" /output/mosquitto
ls -lh /output/mosquitto
