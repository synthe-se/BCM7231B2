# Shared by the in-container build scripts (sourced, not run).

# fetch <tarball> <url>: download into the /dl cache once; a partial download never passes for a
# complete one (.part, renamed at the end)
fetch() {
    [ -f "/dl/$1" ] && return
    echo "[*] Downloading $2 ..."
    wget -q -O "/dl/$1.part" "$2"
    mv "/dl/$1.part" "/dl/$1"
}

# build_openssl <source dir> <prefix>: OpenSSL's static libraries for the box (linux-mips32, no
# assembly: the generic MIPS code paths assume R2) installed under <prefix> (lib/, include/).
# One recipe for every user: rust-build.sh (the sources the `openssl` crate vendors) and
# mosquitto-build.sh (the pinned release).
build_openssl() {
    local src="$1" prefix="$2" cross
    cross="$(cat /opt/cross-prefix)"
    rm -rf /tmp/ossl "$prefix" && cp -r "$src" /tmp/ossl
    (cd /tmp/ossl && ./Configure linux-mips32 no-shared no-asm no-tests no-docs no-dso no-engine \
        --prefix="$prefix" --libdir=lib CC="${cross}-gcc" AR="${cross}-ar" RANLIB="${cross}-ranlib" \
        -march=mips32 >/dev/null && make -j"$(nproc)" build_libs >/dev/null && make install_dev >/dev/null)
    rm -rf /tmp/ossl
}
