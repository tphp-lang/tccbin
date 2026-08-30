#!/bin/bash
# =============================================================
# musl 静态 sysroot 组装（可移植脚本：macOS / Linux 通用）
# 从 Debian 池目录下载 musl-dev（头文件+CRT+静态库）与 linux-libc-dev
# （UAPI 头），解包展平后组装到 <pkg>/sysroot/<目标>/{include,lib}。
# 用法: bash build-sysroot.sh <tcc源码树> <pkg目录>
#   源码树需已含 <目标>-libtcc1.a（make cross-<目标> 产物）与 include/*.h
#   （tcc 编译器自带头，组装时覆盖 musl 同名头）。
# 兼容 macOS 自带 bash 3.2（不使用 bash4 特性）。
# 注意: build-cross-win.sh 中的同名逻辑与本脚本同源，改动需两边同步。
# =============================================================
set -e
set -o pipefail

SRC_TREE="$1"; PKG_DIR="$2"
if [ -z "$SRC_TREE" ] || [ ! -d "$SRC_TREE" ] || [ -z "$PKG_DIR" ]; then
    echo "[ERROR] 用法: bash build-sysroot.sh <tcc源码树> <pkg目录>"; exit 1
fi

DEB_BASE="${DEB_BASE:-http://ftp.de.debian.org/debian/pool/main}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

download() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 5 -o "$2" "$1"
    else
        wget -q --tries=3 --waitretry=5 -O "$2" "$1"
    fi
}

upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

ver_from() {  # $1=包名 $2=deb架构 $3=池列表文件 → 最新版本号
    grep -o "${1}_[^\"]*_${2}\.deb" "$3" | sort -uV | tail -1 | cut -d_ -f2
}

extract_deb() {  # $1=deb $2=解压目标
    local deb dest
    deb="$(realpath "$1" 2>/dev/null || echo "$1")"
    dest="$2"
    mkdir -p "$dest"
    ( cd "$dest" && ar x "$deb" ) || { echo "[ERROR] ar 解包失败: $deb"; exit 1; }
    if [ -f "$dest/data.tar.zst" ]; then
        if command -v zstd >/dev/null 2>&1; then
            zstd -dcf "$dest/data.tar.zst" | ( cd "$dest" && tar -xf - ) \
                || echo "[WARN] data.tar 解压有报错（Windows 下符号链接无法建链属预期，断言把关）"
        else
            ( cd "$dest" && tar -xf data.tar.zst ) \
                || echo "[WARN] data.tar 解压有报错（bsdtar 自动解压；符号链接限制可忽略）"
        fi
    else
        ( cd "$dest" && tar -xf data.tar.* ) \
            || echo "[WARN] data.tar 解压有报错（符号链接限制可忽略）"
    fi
    ( cd "$dest" && rm -f debian-binary control.tar.* data.tar.* )
}

assemble() {  # $1=目标(x86_64/arm64) $2=deb架构 $3=musl triplet
    local T="$1" DARCH="$2" MA="$3"
    local PKGINC="$PKG_DIR/sysroot/$T/include" PKGLIB="$PKG_DIR/sysroot/$T/lib"
    local MUSLROOT="$STAGE/musl-$DARCH/usr"
    echo "[*] 组装 sysroot/$T（musl $MUSL_VER / $DARCH）..."
    mkdir -p "$PKGINC" "$PKGLIB"
    # musl 头文件：Debian 打包在 /usr/include/<musl-triplet>/ 下，整体展平
    if [ -d "$MUSLROOT/include/$MA" ]; then
        cp -r "$MUSLROOT/include/$MA/." "$PKGINC/"
    elif [ -d "$MUSLROOT/include/bits" ]; then
        cp -r "$MUSLROOT/include/." "$PKGINC/"
    else
        echo "[ERROR] musl-dev ($DARCH) 中未找到头文件目录"; exit 1
    fi
    # tcc 编译器自带头（stddef.h/stdarg.h/float.h/stdatomic.h 等）：
    # musl 不含编译器提供的头（stdio.h 依赖 stddef.h），且 stdatomic.h
    # 必须用 tcc 版本，-f 覆盖 musl 同名头
    cp -f "$SRC_TREE"/include/*.h "$PKGINC/"
    # Linux UAPI 头（用户代码引用 <linux/...>、<asm/...> 时需要）
    cp -rL "$STAGE/lld-$DARCH/usr/include/linux"       "$PKGINC/linux"
    cp -rL "$STAGE/lld-$DARCH/usr/include/asm-generic" "$PKGINC/asm-generic"
    if [ -d "$STAGE/lld-$DARCH/usr/include/$MA/asm" ]; then
        cp -rL "$STAGE/lld-$DARCH/usr/include/$MA/asm" "$PKGINC/asm"
    fi
    # CRT + 静态库（musl：crt1/crti/crtn + libc.a；math 已并入 libc，
    # libm.a 为兼容占位；libpthread/libdl 已并入 libc 无需单独提供）
    for f in crt1.o crti.o crtn.o libc.a libm.a; do
        if [ -f "$MUSLROOT/lib/$MA/$f" ]; then
            cp "$MUSLROOT/lib/$MA/$f" "$PKGLIB/"
        fi
    done
    # 交叉 tcc 自举编译的运行时支持库（make cross-<T> 产物）
    cp "$SRC_TREE/$T-libtcc1.a" "$PKGLIB/"
    # 关键文件断言：防止静默产出残缺 sysroot
    for f in "$PKGINC/stdio.h" "$PKGINC/bits/alltypes.h" "$PKGINC/stddef.h" \
             "$PKGINC/linux/limits.h" \
             "$PKGLIB/crt1.o" "$PKGLIB/libc.a" "$PKGLIB/$T-libtcc1.a"; do
        if [ ! -f "$f" ]; then
            echo "[ERROR] sysroot/$T 缺少关键文件: $f"; exit 1
        fi
    done
    echo "    头文件 $(find "$PKGINC" -type f | wc -l) 个, 支持库 $(ls "$PKGLIB" | wc -l) 个"
}

echo "[*] 解析 musl / linux-libc-dev 最新版本..."
MUSL_POOL="$STAGE/musl-pool.html"
LLD_POOL="$STAGE/lld-pool.html"
if download "$DEB_BASE/m/musl/" "$MUSL_POOL"; then
    MUSL_VER_AMD64="$(ver_from musl-dev amd64 "$MUSL_POOL")"
    MUSL_VER_ARM64="$(ver_from musl-dev arm64 "$MUSL_POOL")"
else
    echo "[WARN] Debian 池目录（musl）不可达"
fi
if download "$DEB_BASE/l/linux/" "$LLD_POOL"; then
    LLD_VER_AMD64="$(ver_from linux-libc-dev amd64 "$LLD_POOL")"
    LLD_VER_ARM64="$(ver_from linux-libc-dev arm64 "$LLD_POOL")"
else
    echo "[WARN] Debian 池目录（linux）不可达，UAPI 头将缺失"
fi

for spec in "x86_64 amd64 x86_64-linux-musl" "arm64 arm64 aarch64-linux-musl"; do
    set -- $spec
    T="$1"; DARCH="$2"; MA="$3"

    VAR="MUSL_VER_$(upper "$DARCH")"; MUSL_VER="${!VAR}"
    if [ -z "$MUSL_VER" ]; then
        echo "[ERROR] musl-dev ($DARCH) 版本解析失败"; exit 1
    fi
    echo "[*] 下载 musl-dev $MUSL_VER ($DARCH)..."
    download "$DEB_BASE/m/musl/musl-dev_${MUSL_VER}_${DARCH}.deb" "$STAGE/musl-dev-$DARCH.deb"
    extract_deb "$STAGE/musl-dev-$DARCH.deb" "$STAGE/musl-$DARCH"

    VAR="LLD_VER_$(upper "$DARCH")"; LLD_VER="${!VAR}"
    if [ -z "$LLD_VER" ]; then
        echo "[ERROR] linux-libc-dev ($DARCH) 版本解析失败，无法组装 UAPI 头"; exit 1
    fi
    echo "[*] 下载 linux-libc-dev $LLD_VER ($DARCH)..."
    download "$DEB_BASE/l/linux/linux-libc-dev_${LLD_VER}_${DARCH}.deb" "$STAGE/lld-$DARCH.deb"
    extract_deb "$STAGE/lld-$DARCH.deb" "$STAGE/lld-$DARCH"

    assemble "$T" "$DARCH" "$MA"
done

echo "[+] musl sysroot 组装完成 → $PKG_DIR/sysroot/"
