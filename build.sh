#!/bin/bash
# =============================================================
# 构建独立 TCC（Linux / macOS 通用，参考 Vlang)
# 用法: bash build.sh（在项目根目录执行）
# =============================================================
set -e
set -o pipefail

OS="$(uname -s)"

echo "=== 1. 克隆 TCC 源码 ==="
# 记下项目根目录绝对路径 — TCC 的 --prefix 必须用绝对路径
# 否则 TCC 初始化时从 CWD 解析相对路径，会找错 libtcc1.a 的位置
PROJECT_ROOT="$(pwd)"
rm -rf tcc-src tcc
# 最多重试 3 次（repo.or.cz 网络不稳定）
for i in 1 2 3; do
  echo "[*] 第 $i 次尝试克隆 TCC (mob 分支)..."
  if git clone --depth 1 --branch mob https://repo.or.cz/tinycc.git tcc-src 2>/dev/null; then
    break
  fi
  [ "$i" -lt 3 ] && sleep 10
done
if [ ! -d tcc-src ]; then
  echo "[ERROR] 无法从 repo.or.cz 克隆 TCC 源码（重试 3 次均失败）"
  exit 1
fi
cd tcc-src

echo "=== 2. 配置 TCC ==="
echo "       prefix = $PROJECT_ROOT/tcc"
if [ "$OS" = "Darwin" ]; then
    SDK=$(xcrun --show-sdk-path)
    ./configure \
        --prefix="$PROJECT_ROOT/tcc" \
        --bindir="$PROJECT_ROOT/tcc" \
        --crtprefix="../tcc/lib/tcc:$SDK/usr/lib" \
        --libpaths="../tcc/lib/tcc:$SDK/usr/lib:/usr/lib:/usr/local/lib" \
        --sysincludepaths="../tcc/lib/tcc/include:$SDK/usr/include:/usr/local/include" \
        --extra-cflags="-I$SDK/usr/include -O3" \
        --cc=cc \
        --config-new_macho=yes \
        --config-codesign=yes \
        --config-bcheck=yes \
        --config-backtrace=yes \
        --enable-static
else
    ARCH=$(gcc -dumpmachine)
    ./configure \
        --prefix="$PROJECT_ROOT/tcc" \
        --bindir="$PROJECT_ROOT/tcc" \
        --crtprefix="lib/tcc:/usr/lib/$ARCH:/usr/lib64:/usr/lib:/lib/$ARCH:/lib" \
        --libpaths="lib/tcc:/usr/lib/$ARCH:/usr/lib64:/usr/lib:/lib/$ARCH:/lib:/usr/local/lib/$ARCH:/usr/local/lib" \
        --extra-cflags=-O3 \
        --config-bcheck=yes \
        --config-backtrace=yes
fi

echo "=== 3. 编译 & 安装 ==="
# glibc 2.34+ removed all malloc hooks. bcheck can't intercept malloc/free.
# Provide no-op stubs so TCC's --config-bcheck instrumentation links cleanly.
cat > lib/bcheck.c << 'BCHECK_STUBS'
void __bound_init(void) {}
void __bound_new_region(void *p, unsigned long size) {}
void __bound_delete_region(void *p) {}
int  __bound_check(void *p, unsigned long size) { return 0; }
void *__bound_ptr_add(void *p, unsigned long offset) { return (char*)p + offset; }
void *__bound_ptr_indir(void *p, unsigned long offset, unsigned long size) { return (char*)p + offset; }
void __bound_local_new(void *p) {}
void __bound_local_delete(void *p) {}
void __bound_sigjb(int sig, void *jb) {}
BCHECK_STUBS
make
make install

echo "=== 4. 整理 TCC 目录结构 ==="
mkdir -p ../tcc/include
cp -r ../tcc/lib/tcc/include/* ../tcc/include/ 2>/dev/null || true

# ── Linux: 从 Debian 官方源下载 libc6-dev + libc6 解压 → 独立编译工具链 ──
if [ "$OS" != "Darwin" ]; then
    MACHINE=$(uname -m)
    case "$MACHINE" in
        x86_64)  DEB_ARCH="amd64"  ;;
        aarch64) DEB_ARCH="arm64"  ;;
        *) echo "[ERROR] 不支持的架构: $MACHINE"; exit 1 ;;
    esac

    LIBC_VER="2.41-12+deb13u3"
    LIBC_BASE="http://ftp.de.debian.org/debian/pool/main/g/glibc"
    LIBC_DEV_URL="${LIBC_BASE}/libc6-dev_${LIBC_VER}_${DEB_ARCH}.deb"
    LIBC_URL="${LIBC_BASE}/libc6_${LIBC_VER}_${DEB_ARCH}.deb"

    TCC_LIB=../tcc/lib/tcc
    TCC_INC="$TCC_LIB/include"
    TMPDIR=$(mktemp -d)
    trap "rm -rf $TMPDIR" EXIT

    # ── 下载辅助函数 ──
    download_deb() {
        local url="$1" out="$2"
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --retry 3 --retry-delay 5 -o "$out" "$url"
        else
            wget -q --tries=3 --waitretry=5 -O "$out" "$url"
        fi
    }

    # ── 解压 .deb 辅助函数（兼容 dpkg-deb 和 ar+tar） ──
    extract_deb() {
        local deb="$1" dest="$2"
        mkdir -p "$dest"
        if command -v dpkg-deb >/dev/null 2>&1; then
            dpkg-deb -x "$deb" "$dest"
        else
            (cd "$dest" && ar x "$deb" data.tar.* && tar xf data.tar.* && rm -f data.tar.*)
        fi
    }

    # ── 下载并解压 libc6-dev（头文件 + CRT + 静态库） ──
    echo "[*] 下载 libc6-dev ($DEB_ARCH) ..."
    download_deb "$LIBC_DEV_URL" "$TMPDIR/libc6-dev.deb"
    if [ ! -s "$TMPDIR/libc6-dev.deb" ]; then
        echo "[ERROR] 下载 libc6-dev 失败: $LIBC_DEV_URL"
        exit 1
    fi
    echo "[*] 解压 libc6-dev ..."
    extract_deb "$TMPDIR/libc6-dev.deb" "$TMPDIR/dev-root"

    # 多架构 triplet（gcc -dumpmachine → x86_64-linux-gnu / aarch64-linux-gnu）
    MULTIARCH=$(gcc -dumpmachine 2>/dev/null || echo "$MACHINE-linux-gnu")

    # 复制头文件（-n = no-clobber，不覆盖 TCC 自有头文件如 stdarg.h/stddef.h）
    # 注意：Debian 多架构包中 bits/、gnu/、sys/、fpu_control.h 等在
    #       usr/include/{triplet}/ 下，需要先复制到顶层，否则 TCC 找不到
    echo "[*] 安装系统头文件 → $TCC_INC"
    # 第1步：复制顶层通用头文件（-n 保留 TCC 自有头文件）
    cp -rn "$TMPDIR/dev-root/usr/include/"* "$TCC_INC/"
    # 第2步：复制多架构目录内容到顶层（bits/libc-header-start.h 等在此）
    if [ -d "$TMPDIR/dev-root/usr/include/$MULTIARCH" ]; then
        cp -rn "$TMPDIR/dev-root/usr/include/$MULTIARCH/"* "$TCC_INC/"
    fi
    echo "    头文件: $(find "$TCC_INC" -type f | wc -l) 个"

    # 验证关键头文件存在
    if [ ! -f "$TCC_INC/bits/libc-header-start.h" ]; then
        echo "[WARN] bits/libc-header-start.h 缺失！尝试从系统补充..."
        if [ -f "/usr/include/$MULTIARCH/bits/libc-header-start.h" ]; then
            mkdir -p "$TCC_INC/bits"
            cp -v "/usr/include/$MULTIARCH/bits/libc-header-start.h" "$TCC_INC/bits/"
        elif [ -f "/usr/include/bits/libc-header-start.h" ]; then
            mkdir -p "$TCC_INC/bits"
            cp -v "/usr/include/bits/libc-header-start.h" "$TCC_INC/bits/"
        else
            echo "[ERROR] 无法找到 bits/libc-header-start.h，编译将失败！"
        fi
    fi

    # 复制 CRT + 静态库 + 链接脚本
    echo "[*] 安装 CRT + 链接库 → $TCC_LIB"
    CRT_COUNT=0
    for libdir in "$TMPDIR/dev-root/usr/lib/$MULTIARCH" "$TMPDIR/dev-root/usr/lib"; do
        if [ -d "$libdir" ]; then
            cp -v "$libdir"/crt*.o "$TCC_LIB/" 2>/dev/null && CRT_COUNT=$(($CRT_COUNT + $(ls "$libdir"/crt*.o 2>/dev/null | wc -l)))
            cp -v "$libdir"/Mcrt1.o "$TCC_LIB/" 2>/dev/null && CRT_COUNT=$((CRT_COUNT+1))
            for lib in libc libm libpthread libdl libc_nonshared; do
                cp -v "$libdir/${lib}.a"   "$TCC_LIB/" 2>/dev/null || true
                cp -v "$libdir/${lib}.so"  "$TCC_LIB/" 2>/dev/null || true
            done
            break
        fi
    done
    # 修复 libc.so 链接器脚本：将绝对路径改为相对路径（PHAR 内文件都是平铺的）
    if [ -f "$TCC_LIB/libc.so" ] && grep -q 'GROUP' "$TCC_LIB/libc.so" 2>/dev/null; then
        sed -i 's|/lib/[^ ]*/libc\.so\.[0-9.]*|libc.so.6|g' "$TCC_LIB/libc.so"
        sed -i 's|/usr/lib/[^ ]*/libc_nonshared\.a|libc_nonshared.a|g' "$TCC_LIB/libc.so"
        echo "    [FIX] libc.so 链接器脚本 → 相对路径"
    fi

    echo "    CRT: ${CRT_COUNT} 个  静态库: $(find "$TCC_LIB" -name '*.a' -type f | wc -l)"

    # ── 下载并解压 libc6（运行时 .so） ──
    echo "[*] 下载 libc6 ($DEB_ARCH) ..."
    download_deb "$LIBC_URL" "$TMPDIR/libc6.deb"
    if [ ! -s "$TMPDIR/libc6.deb" ]; then
        echo "[WARN] 下载 libc6 失败，跳过运行时 .so（仅静态链接可用）"
    else
        echo "[*] 解压 libc6 ..."
        extract_deb "$TMPDIR/libc6.deb" "$TMPDIR/rt-root"
        # 复制 .so 运行时库和动态链接器
        SO_COUNT=0
        for sodir in "$TMPDIR/rt-root/lib/$MULTIARCH" "$TMPDIR/rt-root/lib"; do
            if [ -d "$sodir" ]; then
                cp -v "$sodir"/libc.so.*   "$TCC_LIB/" 2>/dev/null && SO_COUNT=$((SO_COUNT+1))
                cp -v "$sodir"/libm.so.*   "$TCC_LIB/" 2>/dev/null && SO_COUNT=$((SO_COUNT+1))
                cp -v "$sodir"/ld-*.so*    "$TCC_LIB/" 2>/dev/null || true
                break
            fi
        done
        echo "    运行时 .so: ${SO_COUNT}+"
    fi

    echo "[+] glibc 工具链安装完成（Debian ${LIBC_VER} / ${DEB_ARCH}）"
fi

if [ "$OS" = "Darwin" ]; then
    # macOS: link libc for Big Sur+
    ln -sf /usr/lib/libSystem.B.dylib ../tcc/lib/tcc/libc.dylib 2>/dev/null || true
fi

echo "=== 6. 验证 ==="
cd ..
echo 'int main(){return 0;}' > _test_tcc.c
# TCC 的 crtprefix/libpaths 用相对路径 lib/tcc，从 CWD 解析
# chdir 到 tcc/ 后: lib/tcc → tcc/lib/tcc/ → libtcc1.a + CRT 文件都在这里
(cd tcc && ./tcc -B"$(pwd)/lib/tcc" -o ../_test_tcc ../_test_tcc.c) && {
    echo "TCC standalone OK"
    rm -f _test_tcc
} || {
    echo "TCC FAILED"
    exit 1
}
rm -f _test_tcc.c

echo "=== 7. 清理 ==="
rm -rf tcc-src

echo ""
echo "✓ 独立 TCC 构建完成"
echo "  二进制: $PWD/tcc/tcc"
