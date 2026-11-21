#!/bin/bash
# In-container nftables build (static, musl, MIPS32 R1), invoked by `make nft`.
# `nft` loads the Maison role's one ruleset: mosquitto's 8883 for the Meross plugs alone
# (rootfs/maison/usr/sbin/mosquitto-run). libmnl and libnftnl built static first; nft with its
# mini-gmp, no readline (no interactive mode), no JSON, no Python.
# Output: /output/nft
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

LIBMNL_VERSION="${LIBMNL_VERSION:?LIBMNL_VERSION not set}"
LIBNFTNL_VERSION="${LIBNFTNL_VERSION:?LIBNFTNL_VERSION not set}"
NFTABLES_VERSION="${NFTABLES_VERSION:?NFTABLES_VERSION not set}"
CROSS="$(cat /opt/cross-prefix)"
# www.netfilter.org refuses scripted clients; the same files under /pub
PUB=https://netfilter.org/pub

echo "nftables ${NFTABLES_VERSION} (libnftnl ${LIBNFTNL_VERSION}, libmnl ${LIBMNL_VERSION}): static, MIPS32 R1"

fetch "libmnl-${LIBMNL_VERSION}.tar.bz2" "$PUB/libmnl/libmnl-${LIBMNL_VERSION}.tar.bz2"
fetch "libnftnl-${LIBNFTNL_VERSION}.tar.xz" "$PUB/libnftnl/libnftnl-${LIBNFTNL_VERSION}.tar.xz"
fetch "nftables-${NFTABLES_VERSION}.tar.xz" "$PUB/nftables/nftables-${NFTABLES_VERSION}.tar.xz"

BUILDDIR=/tmp/nft
PREFIX=/tmp/nft-prefix
rm -rf "$BUILDDIR" "$PREFIX"; mkdir -p "$BUILDDIR"
for t in "libmnl-${LIBMNL_VERSION}.tar.bz2" "libnftnl-${LIBNFTNL_VERSION}.tar.xz" "nftables-${NFTABLES_VERSION}.tar.xz"; do
    tar xf "/dl/$t" -C "$BUILDDIR"
done

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
COMMON=(--host="${CROSS}" --prefix="$PREFIX" --enable-static --disable-shared
    CC="${CROSS}-gcc" CFLAGS="-Os")

# build <dir> <make's extra variables> <configure's extra options...>
build() {
    echo "[*] $1..."
    (cd "$BUILDDIR/$1" && ./configure "${COMMON[@]}" "${@:3}" >/dev/null \
        && make -j"$(nproc)" ${2:+"$2"} >/dev/null && make install >/dev/null)
}
build "libmnl-${LIBMNL_VERSION}" ""
build "libnftnl-${LIBNFTNL_VERSION}" ""
# -all-static is libtool's (a static nft, not only static libraries): make's, never configure's,
# whose compiler test would refuse it
build "nftables-${NFTABLES_VERSION}" "LDFLAGS=-all-static" --with-mini-gmp --without-cli \
    --without-json --disable-man-doc

NFT="$PREFIX/sbin/nft"
[ -f "$NFT" ] || { echo "!!! BUILD FAILED: nft missing !!!"; exit 1; }
file "$NFT" | grep -q 'statically linked' || { echo "!!! nft is not static !!!"; file "$NFT"; exit 1; }
cp "$NFT" /output/nft
"${CROSS}-strip" /output/nft
ls -lh /output/nft
