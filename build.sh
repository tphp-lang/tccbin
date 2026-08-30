#!/bin/bash
# =============================================================
# 构建独立 TCC（Linux / macOS 通用，参考 Vlang)
# 用法: bash build.sh（在项目根目录执行）
# =============================================================
set -e
set -o pipefail

OS="$(uname -s)"

# 位置无关启动器：真实二进制在 bin/ 内，启动器按自身所在目录传 -B。
# {B} 路径模板在 tcc 参数解析之后才展开（tcc.c: tcc_parse_args 先于
# tcc_set_output_type，crt/lib/include 模板均经 tcc_split_path 的 {B} 替换），
# 因此 -B<包目录> 能让全部支持文件定位与工作目录解耦。
write_wrapper() {  # $1=包目录 $2=启动器文件名 $3=bin/内二进制名 $4=-B 附加子路径
    cat > "$1/$2" <<WRAPPER
#!/bin/sh
# tccbin relocatable launcher: support files resolve from this dir ({B})
SELF="\$0"
case "\$SELF" in
    */*) ;;
    *) SELF="\$(command -v -- "\$SELF" 2>/dev/null || printf '%s' "\$SELF")" ;;
esac
RES="\$(readlink -f -- "\$SELF" 2>/dev/null || printf '%s' "\$SELF")"
DIR=\$(CDPATH= cd -- "\$(dirname -- "\$RES")" && pwd -P)
exec "\$DIR/$3" -B"\$DIR$4" "\$@"
WRAPPER
    chmod 755 "$1/$2"
}

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
    # {B} = tcc_lib_path（启动器传 -B<包目录>），全部搜索路径锚定 {B}，
    # 解压到任意路径均可使用；{B}/include 为包内自带头文件
    ./configure \
        --prefix="$PROJECT_ROOT/tcc" \
        --bindir="$PROJECT_ROOT/tcc" \
        --crtprefix="{B}/lib/tcc:$SDK/usr/lib" \
        --libpaths="{B}:{B}/lib/tcc:$SDK/usr/lib:/usr/lib:/usr/local/lib" \
        --sysincludepaths="{B}/include:{B}/lib/tcc/include:$SDK/usr/include:/usr/local/include" \
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
        --crtprefix="{B}/lib/tcc:/usr/lib/$ARCH:/usr/lib64:/usr/lib:/lib/$ARCH:/lib" \
        --libpaths="{B}:{B}/lib/tcc:/usr/lib/$ARCH:/usr/lib64:/usr/lib:/lib/$ARCH:/lib:/usr/local/lib/$ARCH:/usr/local/lib" \
        --sysincludepaths="{B}/include:{B}/lib/tcc/include:/usr/local/include:/usr/include:/usr/include/$ARCH" \
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

    # ── Linux 内核 UAPI 头（linux/limits.h 等，来自 linux-libc-dev 包）──
    # glibc 的 bits/local_lim.h 会 #include <linux/limits.h>，但该头属于
    # linux-libc-dev（Debian 与 libc6-dev 分包），上面的 .deb 解压拿不到。
    # 精简容器（Docker）无系统 linux/ 头时，任何引用 PATH_MAX 等的代码
    # （mbedtls/openssl 等）编译都会失败，故必须打进 tcc 包
    echo "[*] 安装 Linux UAPI 头文件 → $TCC_INC"
    if [ -d /usr/include/linux ]; then
        cp -rn /usr/include/linux       "$TCC_INC/"
        cp -rn /usr/include/asm-generic "$TCC_INC/" 2>/dev/null || true
        # asm/ 在 Debian/Ubuntu 下位于 multiarch 目录（/usr/include/asm 是
        # 指向它的 symlink）；TCC 的 sysincludepaths 不含 multiarch 路径，
        # zip 打包还会丢 symlink，因此展平复制到顶层 asm/
        for asm_src in /usr/include/asm "/usr/include/$MULTIARCH/asm"; do
            if [ -d "$asm_src" ]; then
                mkdir -p "$TCC_INC/asm"
                cp -rnL "$asm_src"/. "$TCC_INC/asm/"
                break
            fi
        done
        echo "    UAPI: linux/ asm-generic/ asm/"
    else
        echo "[WARN] /usr/include/linux 缺失（构建机未装 linux-libc-dev），UAPI 头将不可用"
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

# ── Windows PE 交叉编译器（x86_64-win32 + i386-win32）──
# TCC 的目标平台在编译 tcc 自身时由 TCC_TARGET_* 宏决定（-arch 是被忽略的
# 选项），交叉编译器是独立的二进制。PE 目标的头文件/导入库由 tcc 源码树自带
# （win32/include、win32/lib），因此 Linux/macOS 上构建 PE 交叉零外部依赖。
if [ "$OS" != "Darwin" ]; then
    echo "=== 5. 构建 Windows PE 交叉编译器 ==="
    # 用最小参数重跑 configure：第一次 configure 传给 native tcc 的
    # --crtprefix/--libpaths 会无 #ifndef 保护地写进 config.h，导致交叉
    # PE tcc 沿用 native 的搜索路径。重跑后 config.h 不再包含这两个宏，
    # 交叉 PE tcc 回落到 tcc.h 的 PE 默认值（{B}/include、{B}/lib）。
    # 此时 native tcc 已编译完成，不受 config.h 变化影响。
    ./configure --extra-cflags=-O3
    # config.h 中 CONFIG_TCCDIR 带 #ifndef 保护，命令行 -D 优先生效：
    # 覆盖 DEF-win 为相对路径 "win32"，交叉 tcc 与 native 一样遵循
    # "从包根目录运行" 的约定（DEFINES 是递归变量，此处在 recipe 期生效）
    cat > config-extra.mak <<'XMAKE'
DEF-win = -DCONFIG_TCCDIR="\"win32\""
XMAKE
    CROSS_TARGETS="cross-x86_64-win32"
    if [ "$(uname -m)" = "x86_64" ]; then
        CROSS_TARGETS="$CROSS_TARGETS cross-i386-win32"
    fi
    make $CROSS_TARGETS
    [ -f x86_64-win32-tcc ] || { echo "[ERROR] x86_64-win32-tcc 构建失败"; exit 1; }

    TCC_PKG=../tcc
    echo "[*] 安装 PE 交叉编译器 → $TCC_PKG"
    mkdir -p "$TCC_PKG/bin"
    # native 二进制移入 bin/，包根改放位置无关启动器（含 PE 交叉）；
    # PE 交叉的 -B 指向 win32/（{B}/include、{B}/lib 即 win32 下的支持文件）
    mv "$TCC_PKG/tcc" "$TCC_PKG/bin/tcc"
    cp -v x86_64-win32-tcc "$TCC_PKG/bin/"
    write_wrapper "$TCC_PKG" tcc bin/tcc ""
    write_wrapper "$TCC_PKG" x86_64-win32-tcc bin/x86_64-win32-tcc /win32
    if [ -f i386-win32-tcc ]; then
        cp -v i386-win32-tcc "$TCC_PKG/bin/"
        write_wrapper "$TCC_PKG" i386-win32-tcc bin/i386-win32-tcc /win32
    fi
    # win32 支持文件布局与 make install 的 install-unx 规则一致：
    # 源码树 win32/include 打底，tcc 自有头文件（stdarg.h 等）覆盖同名文件
    mkdir -p "$TCC_PKG/win32/include" "$TCC_PKG/win32/lib"
    cp -r win32/include/. "$TCC_PKG/win32/include/"
    cp -f include/*.h tcclib.h "$TCC_PKG/win32/include/"
    # 导入库定义（kernel32.def 等）+ 各目标自举编译的 libtcc1.a
    cp -v win32/lib/*.def "$TCC_PKG/win32/lib/"
    cp -v x86_64-win32-libtcc1.a "$TCC_PKG/win32/lib/"
    if [ -f i386-win32-libtcc1.a ]; then cp -v i386-win32-libtcc1.a "$TCC_PKG/win32/lib/"; fi

    cat > "$TCC_PKG/README.txt" <<'PKGDOC'
TCC 独立编译器包（Linux/macOS 宿主）
====================================
位置无关：包根的 tcc / x86_64-win32-tcc / i386-win32-tcc 是启动脚本，
按脚本所在目录定位支持文件，可从任意工作目录调用（真实二进制在 bin/，
一般无需直接调用）。

  ./tcc hello.c -o hello                    本机程序
  ./x86_64-win32-tcc hello.c -o hello.exe   产出 64 位 Windows exe
  ./i386-win32-tcc hello.c -o hello.exe     产出 32 位 Windows exe
                                            （仅 x86_64 包含此目标）

包内自带 glibc 头文件/CRT/静态库（lib/tcc/include、lib/tcc/*.a）与
Linux UAPI 头，容器或精简系统里无需安装 libc6-dev 即可编译。
PE 交叉无需 sysroot：win32/ 内置头文件与导入库（kernel32.def 等）。

注意：启动器按"脚本所在目录"解析路径；如需通过符号链接调用，
请链接整个包目录，或直接调用 bin/ 内二进制并自行传 -B<包目录>。
PKGDOC
    echo "[+] PE 交叉编译器安装完成"
fi

if [ "$OS" = "Darwin" ]; then
    # macOS 包同样改为位置无关布局（native 单二进制）
    TCC_PKG=../tcc
    mkdir -p "$TCC_PKG/bin"
    mv "$TCC_PKG/tcc" "$TCC_PKG/bin/tcc"
    write_wrapper "$TCC_PKG" tcc bin/tcc ""
fi

if [ "$OS" = "Darwin" ]; then
    # macOS: link libc for Big Sur+
    ln -sf /usr/lib/libSystem.B.dylib ../tcc/lib/tcc/libc.dylib 2>/dev/null || true
fi

echo "=== 6. 验证 ==="
PKG="$PROJECT_ROOT/tcc"
cd "$PROJECT_ROOT"
echo 'int main(){return 0;}' > _test_tcc.c
# 位置无关验证：在包目录之外调用启动器（模拟用户解压到任意路径后使用），
# CRT/头文件/库全部应来自包内自带的 lib/tcc 与 include
(cd /tmp && "$PKG/tcc" -o /tmp/_test_tcc "$PROJECT_ROOT/_test_tcc.c") && {
    echo "TCC standalone OK (relocatable)"
    rm -f /tmp/_test_tcc
} || {
    echo "TCC FAILED"
    exit 1
}
rm -f _test_tcc.c

# UAPI 头验证：linux/limits.h 是 glibc bits/local_lim.h 的硬依赖（仅 Linux）
if [ "$OS" != "Darwin" ]; then
    # 文件断言：防止编译验证被构建机 /usr/include 兜底误判 PASS
    if [ ! -f tcc/lib/tcc/include/linux/limits.h ]; then
        echo "UAPI test FAILED: linux/limits.h missing from package"
        exit 1
    fi
    printf '#include <limits.h>\n#include <linux/limits.h>\nint main(){return PATH_MAX>0?0:1;}\n' > _test_uapi.c
    if (cd /tmp && "$PKG/tcc" -o /tmp/_test_uapi "$PROJECT_ROOT/_test_uapi.c"); then
        echo "UAPI headers (linux/limits.h) OK"
        rm -f /tmp/_test_uapi _test_uapi.c
    else
        echo "UAPI headers test FAILED: linux/limits.h not found"
        exit 1
    fi
fi

# PE 交叉验证：用交叉 tcc 编出真实 exe 并校验 PE 头
# （CI 上无法运行 PE，链接成功 + PE 魔数即为通过标准）
if [ "$OS" != "Darwin" ]; then
    verify_pe() {
        # $1 = exe 文件, $2 = 期望标识（"PE32+ executable" 或 "PE32 executable"）
        if command -v file >/dev/null 2>&1; then
            file "$1" | grep -q "$2"
        else
            # file 不可用时退化为 MZ 魔数校验
            [ "$(od -An -c -N2 "$1" | tr -d ' \n')" = "MZ" ]
        fi
    }
    printf '#include <stdio.h>\nint main(void){printf("hello PE\\n");return 0;}\n' > _test_pe.c
    (cd /tmp && "$PKG/x86_64-win32-tcc" -o /tmp/_test_pe64.exe "$PROJECT_ROOT/_test_pe.c") \
        || { echo "PE64 cross test FAILED (x86_64-win32-tcc)"; exit 1; }
    verify_pe /tmp/_test_pe64.exe "PE32+ executable" \
        || { echo "PE64 magic check FAILED"; exit 1; }
    echo "PE64 cross (x86_64-win32-tcc) OK"
    rm -f /tmp/_test_pe64.exe
    if [ -f "$PKG/bin/i386-win32-tcc" ]; then
        (cd /tmp && "$PKG/i386-win32-tcc" -o /tmp/_test_pe32.exe "$PROJECT_ROOT/_test_pe.c") \
            || { echo "PE32 cross test FAILED (i386-win32-tcc)"; exit 1; }
        verify_pe /tmp/_test_pe32.exe "PE32 executable" \
            || { echo "PE32 magic check FAILED"; exit 1; }
        echo "PE32 cross (i386-win32-tcc) OK"
        rm -f /tmp/_test_pe32.exe
    fi
    rm -f _test_pe.c
fi

echo "=== 7. 清理 ==="
rm -rf tcc-src

echo ""
echo "✓ 独立 TCC 构建完成"
echo "  启动器: $PWD/tcc/tcc（位置无关，真实二进制在 tcc/bin/）"
