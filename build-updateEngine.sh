#!/bin/bash
set -euo pipefail

# Build a static AArch64 updateEngine binary from this repository together with
# pinned zlib, bzip2, OpenSSL, and libcurl archives using the SDK GCC 10.3 toolchain.

ZLIB_VER="1.3.1"
ZLIB_TAR="zlib-${ZLIB_VER}.tar.xz"
ZLIB_SHA="38ef96b8dfe510d42707d9c781877914792541133e1870841463bfa73f883e32"
ZLIB_URLS=(
    "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/${ZLIB_TAR}"
    "https://sources.buildroot.net/libzlib/${ZLIB_TAR}"
)

BZIP2_VER="1.0.8"
BZIP2_TAR="bzip2-${BZIP2_VER}.tar.gz"
BZIP2_SHA="ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269"
BZIP2_URLS=(
    "https://sourceware.org/pub/bzip2/${BZIP2_TAR}"
    "https://sources.buildroot.net/bzip2/${BZIP2_TAR}"
)

OPENSSL_VER="3.2.1"
OPENSSL_TAR="openssl-${OPENSSL_VER}.tar.gz"
OPENSSL_SHA="83c7329fe52c850677d75e5d0b0ca245309b97e8ecbcfdc1dfdc4ab9fac35b39"
OPENSSL_URLS=(
    "https://www.openssl.org/source/${OPENSSL_TAR}"
    "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/${OPENSSL_TAR}"
    "https://sources.buildroot.net/libopenssl/${OPENSSL_TAR}"
)

CURL_VER="8.6.0"
CURL_TAR="curl-${CURL_VER}.tar.xz"
CURL_SHA="3ccd55d91af9516539df80625f818c734dc6f2ecf9bada33c76765e99121db15"
CURL_URLS=(
    "https://curl.se/download/${CURL_TAR}"
    "https://github.com/curl/curl/releases/download/curl-8_6_0/${CURL_TAR}"
    "https://sources.buildroot.net/libcurl/${CURL_TAR}"
)

die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat >&2 <<EOF
Usage: $0 OUTPUT_DIRECTORY
Environment:
  CROSS_COMPILE  AArch64 toolchain prefix (defaults to SDK GCC 10.3-2021.07)
  JOBS           Parallel make jobs (defaults to nproc)
  ARCH_CFLAGS    Extra target architecture flags (default: -mcpu=cortex-a53 -fstack-protector-strong)
EOF
    exit 1
}

require_tools() {
    local tool
    for tool in curl tar xz gzip make perl sha256sum; do
        command -v "$tool" >/dev/null 2>&1 || die "Missing required host tool: $tool"
    done
}

resolve_toolchain() {
    local sdk_gcc="${RECIPE}/../../prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-"
    PREFIX="${CROSS_COMPILE:-$sdk_gcc}"
    [ -x "${PREFIX}gcc" ] || die "Cross compiler not found: ${PREFIX}gcc"

    TARGET=$("${PREFIX}gcc" -dumpmachine)
    case "$TARGET" in
        aarch64*-linux-gnu*) ;;
        *) die "Expected an AArch64 GNU/Linux compiler, got: $TARGET" ;;
    esac
}

verify_sha256() {
    local digest="$1" file="$2"
    printf '%s  %s\n' "$digest" "$file" | sha256sum -c -
}

fetch_and_extract() {
    local name="$1" digest="$2"
    shift 2
    local archive="${OUTPUT}/${name}" downloaded=0 url

    if [ ! -f "$archive" ]; then
        for url in "$@"; do
            if curl -fL --retry 2 --connect-timeout 30 --max-time 600 "$url" -o "${WORK}/${name}"; then
                verify_sha256 "$digest" "${WORK}/${name}"
                mv "${WORK}/${name}" "$archive"
                downloaded=1
                break
            fi
            rm -f "${WORK}/${name}"
        done
        [ "$downloaded" = 1 ] || die "Failed to download ${name} from configured sources"
    else
        verify_sha256 "$digest" "$archive"
    fi
    tar -xf "$archive" -C "$WORK"
}

build_zlib() {
    local src="${WORK}/zlib-${ZLIB_VER}"
    (
        cd "$src"
        CHOST="$TARGET" CC="${PREFIX}gcc" AR="${PREFIX}ar" RANLIB="${PREFIX}ranlib" \
            CFLAGS="${BASE_CFLAGS_STR} -fPIC" \
            ./configure --static --prefix="$SYSROOT"
        make -j"$JOBS"
        make install
    )
}

build_bzip2() {
    local src="${WORK}/bzip2-${BZIP2_VER}"
    make -C "$src" -j"$JOBS" \
        CC="${PREFIX}gcc" AR="${PREFIX}ar" RANLIB="${PREFIX}ranlib" \
        CFLAGS="${BASE_CFLAGS_STR} -fPIC" libbz2.a
    install -D -m 0644 "${src}/bzlib.h" "${SYSROOT}/include/bzlib.h"
    install -D -m 0644 "${src}/libbz2.a" "${SYSROOT}/lib/libbz2.a"
}

build_openssl() {
    local src="${WORK}/openssl-${OPENSSL_VER}"
    (
        cd "$src"
        CC="${PREFIX}gcc" AR="${PREFIX}ar" RANLIB="${PREFIX}ranlib" \
            ./Configure linux-aarch64 \
            --prefix="$SYSROOT" --libdir=lib --openssldir=/etc/ssl \
            threads no-shared no-rc5 enable-camellia no-docs no-tests \
            no-fuzz-libfuzzer no-fuzz-afl no-afalgeng zlib no-dso \
            --with-zlib-include="${SYSROOT}/include" \
            --with-zlib-lib="${SYSROOT}/lib" \
            "${BASE_CFLAGS_ARR[@]}" -fPIC
        make -j"$JOBS" build_libs
        make install_dev
    )
}

build_curl() {
    local src="${WORK}/curl-${CURL_VER}"
    (
        cd "$src"
        PKG_CONFIG_LIBDIR="${SYSROOT}/lib/pkgconfig" \
        CC="${PREFIX}gcc" AR="${PREFIX}ar" RANLIB="${PREFIX}ranlib" \
        CPPFLAGS="-I${SYSROOT}/include" \
        CFLAGS="${BASE_CFLAGS_STR} -fPIC" \
        LDFLAGS="-L${SYSROOT}/lib" \
        LIBS="-lz -ldl -lpthread" \
        ./configure \
            --host="$TARGET" --prefix="$SYSROOT" --libdir="${SYSROOT}/lib" \
            --disable-shared --enable-static \
            --enable-ipv6 --disable-nls --disable-manual \
            --disable-ntlm --disable-ntlm-wb \
            --disable-curldebug --disable-libcurl-option \
            --disable-ldap --disable-ldaps \
            --enable-threaded-resolver --disable-verbose \
            --with-openssl="$SYSROOT" --with-zlib="$SYSROOT" \
            --with-ca-path=/etc/ssl/certs --with-random=/dev/urandom \
            --without-libidn2 --without-libpsl --without-libssh2 \
            --without-brotli --without-nghttp2 --without-libgsasl \
            --disable-ares --disable-websockets \
            --enable-cookies --enable-proxy \
            --enable-dict --enable-gopher --enable-imap --enable-pop3 \
            --enable-rtsp --enable-smb --enable-smtp --enable-telnet --enable-tftp
        make -j"$JOBS" -C lib
        make -C lib install
        make -C include install
    )
}

build_update_engine() {
    local src="${WORK}/recovery-src" git_dir="" ue_flags
    mkdir -p "$src"
    tar --exclude=.git -C "$RECIPE" -cf - . | tar -C "$src" -xf -

    if git -C "$RECIPE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git_dir=$(git -C "$RECIPE" rev-parse --absolute-git-dir)
    fi

    ue_flags="${BASE_CFLAGS_STR} -I. -I${SYSROOT}/include -fPIC"
    ue_flags="${ue_flags} -DUSE_UPDATEENGINE=ON -DSUCCESSFUL_BOOT=ON -DHAVE_OPENSSL"
    ue_flags="${ue_flags} -static -L${SYSROOT}/lib"
    ue_flags="${ue_flags} -Wl,--start-group -lcurl -lbz2 -lssl -lcrypto -lz -ldl -lpthread -lc -Wl,--end-group"

    if [ -n "$git_dir" ]; then
        GIT_DIR="$git_dir" make -C "$src" recovery_version
        echo "Version header: $(cat "${src}/recovery_autogenerate.h")"
        GIT_DIR="$git_dir" make -j1 -C "$src" RecoveryNoUi=true CC="${PREFIX}gcc" CFLAGS="$ue_flags" updateEngine
    else
        make -C "$src" recovery_version
        echo "Version header: $(cat "${src}/recovery_autogenerate.h")"
        make -j1 -C "$src" RecoveryNoUi=true CC="${PREFIX}gcc" CFLAGS="$ue_flags" updateEngine
    fi

    "${PREFIX}strip" -o "${OUTPUT}/updateEngine.new" "${src}/updateEngine"
    chmod 0755 "${OUTPUT}/updateEngine.new"
}

verify_output() {
    local bin="$1" elf
    elf=$("${PREFIX}readelf" -hl "$bin")
    grep -Eq 'Machine:[[:space:]]+AArch64$' <<< "$elf" || die "Expected AArch64 ELF"
    if grep -q INTERP <<< "$elf"; then
        die "updateEngine must be statically linked"
    fi
    grep -aqF "CLIENT libcurl ${CURL_VER}" "$bin" || die "Missing expected libcurl ${CURL_VER} signature"
    grep -aqF "OpenSSL ${OPENSSL_VER}" "$bin" || die "Missing expected OpenSSL ${OPENSSL_VER} signature"

    if command -v qemu-aarch64-static >/dev/null 2>&1; then
        local ver
        ver=$(qemu-aarch64-static "$bin" --version 2>&1 || true)
        grep -q 'update_engine: V' <<< "$ver" || die "Unexpected --version output: $ver"
    fi
}

main() {
    [ "$#" = 1 ] || usage
    RECIPE=$(dirname "$(realpath "$0")")
    OUTPUT=$(realpath -m "$1")
    JOBS=${JOBS:-$(nproc)}
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "Invalid JOBS: $JOBS"

    require_tools
    resolve_toolchain
    export LC_ALL=C TZ=UTC

    ARCH_CFLAGS=${ARCH_CFLAGS:--mcpu=cortex-a53 -fstack-protector-strong}
    read -r -a ARCH_CFLAGS_ARR <<< "$ARCH_CFLAGS"
    BASE_CFLAGS_ARR=(
        -D_LARGEFILE_SOURCE -D_LARGEFILE64_SOURCE -D_FILE_OFFSET_BITS=64
        -O2 -g0 -D_FORTIFY_SOURCE=1
        "${ARCH_CFLAGS_ARR[@]}"
    )
    BASE_CFLAGS_STR="${BASE_CFLAGS_ARR[*]}"

    mkdir -p "$OUTPUT"
    WORK=$(mktemp -d "${OUTPUT}/work.XXXXXX")
    SYSROOT="${WORK}/sysroot"
    mkdir -p "${SYSROOT}/include" "${SYSROOT}/lib"

    fetch_and_extract "$ZLIB_TAR" "$ZLIB_SHA" "${ZLIB_URLS[@]}"
    fetch_and_extract "$BZIP2_TAR" "$BZIP2_SHA" "${BZIP2_URLS[@]}"
    fetch_and_extract "$OPENSSL_TAR" "$OPENSSL_SHA" "${OPENSSL_URLS[@]}"
    fetch_and_extract "$CURL_TAR" "$CURL_SHA" "${CURL_URLS[@]}"

    build_zlib
    build_bzip2
    build_openssl
    build_curl
    build_update_engine

    verify_output "${OUTPUT}/updateEngine.new"
    mv "${OUTPUT}/updateEngine.new" "${OUTPUT}/updateEngine"
    sha256sum "${OUTPUT}/updateEngine"
    echo "Built ${OUTPUT}/updateEngine; work tree kept at ${WORK}"
}

main "$@"
