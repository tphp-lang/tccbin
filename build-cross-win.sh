#!/bin/bash
# =============================================================
# Windows 交叉编译器构建 (在 MSYS2/MINGW64 shell 中运行)
# 在 build.cmd 完成 native 构建的基础上：
#   1. configure + make 交叉编译器:
#        i386-win32        → 32 位 Windows PE
#        x86_64 / arm64    → Linux ELF（自带 Debian glibc sysroot）
#   2. 从 Debian 源下载目标架构头文件/CRT/静态库，组装 sysroot/
#   3. 组装 pkg/ 发布目录（native + 3 个交叉编译器 + 支持文件）
# 用法: bash build-cross-win.sh（在项目根目录执行；前置 build.cmd）
# =============================================================
set -e
set -o pipefail

echo "=== C1. 准备 tcc 源码树 ==="
if [ ! -f tcc/win32/tcc.exe ]; then
    echo "[WARN] tcc/win32/tcc.exe 缺失（build.cmd 未先运行?），自行补齐"
    if [ ! -d tcc ]; then
        for i in 1 2 3; do
            git clone --depth 1 --branch mob https://repo.or.cz/tinycc.git tcc 2>/dev/null && break
            [ "$i" -lt 3 ] && sleep 10
        done
    fi
    [ -d tcc ] || { echo "[ERROR] 无法获得 tcc 源码"; exit 1; }
    echo "[*] 补跑 native 构建 (win32/build-tcc.bat)..."
    (cd tcc/win32 && cmd //c build-tcc.bat)
fi
[ -f tcc/win32/tcc.exe ] || { echo "[ERROR] native tcc.exe 不存在"; exit 1; }

cd tcc

echo "=== C2. configure（交叉构建配置）==="
# WIN32 宿主上 configure 不把 CONFIG_TCCDIR 烘进 config.h（tccdir_auto=yes），
# 运行时 {B} 解析为 exe 所在目录 → 发布包解压到任意路径均可工作。
# 此步会覆盖 build-tcc.bat 写的精简 config.h，native tcc.exe 已编译完成不受影响。
./configure --extra-cflags=-O2

echo "=== C3. config-extra.mak（ELF 交叉的 sysroot 路径与静态默认）==="
# 覆盖 Makefile 按 TRIPLET 自动生成的搜索路径（DEFINES 为递归变量，
# 这里的赋值在 recipe 期生效，天然覆盖 TRIPLET 块的同名变量）：
# ELF 交叉编译器的 CRT/库/头文件全部取自 {B}/sysroot/<目标架构>/，
# 其中 {B} = exe 所在目录（运行时解析）。
# 另将 -static 烘进 ELF 交叉编译器（CONFIG_TCC_SWITCHES 在 tcc_new() 中
# 于解析用户参数前应用，同 Android 目标烘 -Wl,-rpath 的机制）：sysroot
# 未带动态 libc，静态链接是这个交叉唯一可用的模式，设为默认免去传参。
# PE 目标（i386-win32）使用 tcc.h 的 PE 默认值 {B}/include、{B}/lib，无需配置。
cat > config-extra.mak <<'XMAKE'
CRT-x86_64 = {B}/sysroot/x86_64/lib
LIB-x86_64 = {B}/sysroot/x86_64
INC-x86_64 = {B}/sysroot/x86_64/include
CRT-arm64  = {B}/sysroot/arm64/lib
LIB-arm64  = {B}/sysroot/arm64
INC-arm64  = {B}/sysroot/arm64/include
DEF-x86_64 += -DCONFIG_TCC_SWITCHES=\"-static\"
DEF-arm64  += -DCONFIG_TCC_SWITCHES=\"-static\"
XMAKE

echo "=== C4. 构建交叉编译器 ==="
make cross-i386-win32 cross-x86_64 cross-arm64
for t in i386-win32 x86_64 arm64; do
    [ -f "$t-tcc.exe" ] || { echo "[ERROR] $t-tcc.exe 构建失败"; exit 1; }
done

echo "=== C5. 下载目标架构 glibc 并组装 sysroot ==="
# glibc 版本与 build.sh 保持一致；linux-libc-dev 版本随内核滚动，
# 从 Debian 池目录动态解析最新版（kernel UAPI 头向后兼容，无需对齐 pin）。
LIBC_VER="2.41-12+deb13u3"
DEB_BASE="http://ftp.de.debian.org/debian/pool/main"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

rm -rf ../pkg
mkdir -p ../pkg/include ../pkg/lib

download() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 5 -o "$2" "$1"
    else
        wget -q --tries=3 --waitretry=5 -O "$2" "$1"
    fi
}

extract_deb() {  # $1 = .deb 文件, $2 = 解压目标目录
    local deb; deb="$(realpath "$1")"
    mkdir -p "$2"
    (
        cd "$2" && ar x "$deb" \
        && if [ -f data.tar.zst ]; then tar --zstd -xf data.tar.zst; else tar -xf data.tar.*; fi
    ) || echo "[WARN] data.tar 解压有报错，见上方日志（Windows 下 tar 无法为指向包外" \
             "文件的 .so 符号链接建链——深层复制语义要求目标在树内。这些链接仅服务" \
             "动态开发，静态 sysroot 不需要；关键文件由 make_sysroot 断言把关）"
    ( cd "$2" && rm -f debian-binary control.tar.* data.tar.* )
}

echo "[*] 解析 linux-libc-dev 最新版本..."
if download "$DEB_BASE/l/linux/" "$STAGE/pool.html"; then
    LLD_VER_AMD64="$(grep -o 'linux-libc-dev_[^"]*_amd64\.deb' "$STAGE/pool.html" | sort -uV | tail -1 | cut -d_ -f2)"
    LLD_VER_ARM64="$(grep -o 'linux-libc-dev_[^"]*_arm64\.deb'  "$STAGE/pool.html" | sort -uV | tail -1 | cut -d_ -f2)"
else
    echo "[WARN] Debian 池目录不可达，linux-libc-dev 版本解析失败"
fi

make_sysroot() {  # $1=目标(x86_64/arm64) $2=deb架构(amd64/arm64) $3=multiarch triplet
    local T="$1" DARCH="$2" MA="$3"
    local PKGINC="../pkg/sysroot/$T/include" PKGLIB="../pkg/sysroot/$T/lib"
    echo "[*] 组装 sysroot/$T（glibc $LIBC_VER / $DARCH）..."
    mkdir -p "$PKGINC" "$PKGLIB"
    # glibc 头文件：顶层通用头 + multiarch 目录内容展平
    # （bits/、gnu/、sys/ 等位于 usr/include/<triplet>/ 下）
    cp -r "$STAGE/dev-$DARCH/usr/include/."     "$PKGINC/"
    cp -r "$STAGE/dev-$DARCH/usr/include/$MA/." "$PKGINC/"
    # Linux UAPI 头：glibc 的 bits/local_lim.h 硬依赖 <linux/limits.h>
    cp -rL "$STAGE/lld-$DARCH/usr/include/linux"       "$PKGINC/linux"
    cp -rL "$STAGE/lld-$DARCH/usr/include/asm-generic" "$PKGINC/asm-generic"
    if [ -d "$STAGE/lld-$DARCH/usr/include/$MA/asm" ]; then
        cp -rL "$STAGE/lld-$DARCH/usr/include/$MA/asm" "$PKGINC/asm"
    fi
    # CRT + 静态库（Linux 目标链接需要 crt1/crti/crtn；crtbegin* 仅 BSD/Android）
    for f in crt1.o crti.o crtn.o Mcrt1.o libc.a libm.a libpthread.a libdl.a librt.a; do
        if [ -f "$STAGE/dev-$DARCH/usr/lib/$MA/$f" ]; then
            cp "$STAGE/dev-$DARCH/usr/lib/$MA/$f" "$PKGLIB/"
        fi
    done
    # 交叉 tcc 自举编译的运行时支持库（make cross-<T> 产物）
    cp "$T-libtcc1.a" "$PKGLIB/"
    # 关键文件断言：防止静默产出残缺 sysroot
    for f in "$PKGINC/bits/libc-header-start.h" "$PKGINC/linux/limits.h" \
             "$PKGINC/asm/types.h" \
             "$PKGLIB/crt1.o" "$PKGLIB/libc.a" "$PKGLIB/$T-libtcc1.a"; do
        if [ ! -f "$f" ]; then
            echo "[ERROR] sysroot/$T 缺少关键文件: $f"; exit 1
        fi
    done
    echo "    头文件 $(find "$PKGINC" -type f | wc -l) 个, 支持库 $(ls "$PKGLIB" | wc -l) 个"
}

for spec in "x86_64 amd64 x86_64-linux-gnu" "arm64 arm64 aarch64-linux-gnu"; do
    set -- $spec
    T="$1"; DARCH="$2"; MA="$3"

    echo "[*] 下载 libc6-dev ($DARCH)..."
    download "$DEB_BASE/g/glibc/libc6-dev_${LIBC_VER}_${DARCH}.deb" "$STAGE/libc6-dev-$DARCH.deb"
    extract_deb "$STAGE/libc6-dev-$DARCH.deb" "$STAGE/dev-$DARCH"

    eval "LLD_VER=\$LLD_VER_${DARCH^^}"
    if [ -z "$LLD_VER" ]; then
        echo "[ERROR] linux-libc-dev ($DARCH) 版本解析失败，无法组装 UAPI 头"; exit 1
    fi
    echo "[*] 下载 linux-libc-dev $LLD_VER ($DARCH)..."
    download "$DEB_BASE/l/linux/linux-libc-dev_${LLD_VER}_${DARCH}.deb" "$STAGE/lld-$DARCH.deb"
    extract_deb "$STAGE/lld-$DARCH.deb" "$STAGE/lld-$DARCH"

    make_sysroot "$T" "$DARCH" "$MA"
done

echo "=== C6. 组装 pkg/ 发布目录 ==="
# 注意：sysroot/ 已在上一步写入 ../pkg，此处只补齐其余文件，不可再清空
# native（build-tcc.bat 产物）：{B}=exe 所在目录 → include/、lib/ 置于包根
cp win32/tcc.exe ../pkg/
if [ -f win32/libtcc.dll ]; then cp win32/libtcc.dll ../pkg/; fi
cp -r win32/include/. ../pkg/include/
cp -f include/*.h tcclib.h ../pkg/include/
cp win32/lib/*.def ../pkg/lib/
if [ -f win32/lib/libtcc1.a ]; then cp win32/lib/libtcc1.a ../pkg/lib/; fi
# PE 交叉（i386-win32）：与 native 共享 include/ lib/，
# 烘进的 CONFIG_TCC_CROSSPREFIX 使其查找 i386-win32-libtcc1.a
cp i386-win32-tcc.exe ../pkg/
cp i386-win32-libtcc1.a ../pkg/lib/
# ELF 交叉（x86_64/arm64）：支持文件已在 sysroot/（见 config-extra.mak）
cp x86_64-tcc.exe arm64-tcc.exe ../pkg/

cat > ../pkg/README.txt <<'PKGDOC'
TCC 独立编译器包（Windows x64 宿主）
====================================
支持文件位置基于 exe 所在目录自动解析，可从任意工作目录调用。

native / PE 交叉:
  tcc.exe hello.c -o hello.exe               64 位 Windows exe
  i386-win32-tcc.exe hello.c -o hello32.exe  32 位 Windows exe
  PE 目标无需 sysroot：include/ 与 lib/ 内置全部头文件和导入库。

交叉编译 Linux ELF（产物拷到对应架构的 Linux 上直接运行）:
  x86_64-tcc.exe hello.c -o hello            Linux x86_64
  arm64-tcc.exe  hello.c -o hello            Linux arm64
  sysroot/<架构>/ 内置目标架构 glibc 头文件与静态库（Debian 13, glibc 2.41）。
  静态链接已是内置默认（-static 已烘进编译器），无需传参；
  动态链接与 -shared 暂不支持。

Windows PE 专属选项示例:
  tcc.exe gui.c -o gui.exe -luser32 -lgdi32 -Wl,-subsystem=windows
  tcc.exe -impdef foo.dll -o foo.def          从 DLL 提取导出定义
  tcc.exe -ar rcs libfoo.a foo.o              打静态库（无需外部 binutils）
PKGDOC

echo "=== C7. 验证 ==="
cd ../pkg
printf '#include <stdio.h>\nint main(void){printf("hello cross\\n");return 0;}\n' > _t.c

# PE 交叉：产出 32 位 exe（CI 无法运行 PE，链接成功 + MZ 魔数即通过）
./i386-win32-tcc _t.c -o _t32.exe || { echo "[ERROR] i386-win32-tcc 测试失败"; exit 1; }
if [ "$(od -An -c -N2 _t32.exe | tr -d ' \n')" != "MZ" ]; then
    echo "[ERROR] _t32.exe 不是 PE 文件"; exit 1
fi
echo "PE32 cross (i386-win32-tcc.exe) OK: $(wc -c < _t32.exe) bytes"

# ELF 交叉（默认静态链接，无需传 -static）：校验 ELF 头 + 目标机器类型
check_elf() {  # $1=文件 $2=期望 e_machine 小端字节（"3e00"=x86_64, "b700"=aarch64）
    local head em
    head="$(od -An -tx1 -N6 "$1" | tr -d ' \n')"
    em="$(od -An -tx1 -j18 -N2 "$1" | tr -d ' \n')"
    [ "$head" = "7f454c460201" ] && [ "$em" = "$2" ]
}
./x86_64-tcc _t.c -o _tx64 || { echo "[ERROR] x86_64-tcc 测试失败"; exit 1; }
if ! check_elf _tx64 "3e00"; then echo "[ERROR] _tx64 不是 x86_64 ELF"; exit 1; fi
# 体积下限：证明默认链接确实拉入了静态 glibc（若 CONFIG_TCC_SWITCHES 烘焙
# 失效，此处走动态链接会先因找不到 libc.so 报错，双重保险）
if [ "$(wc -c < _tx64)" -lt 500000 ]; then
    echo "[ERROR] _tx64 体积异常，默认静态链接可能未生效"; exit 1
fi
echo "ELF x86_64 cross (x86_64-tcc.exe) OK: $(wc -c < _tx64) bytes"
./arm64-tcc _t.c -o _ta64 || { echo "[ERROR] arm64-tcc 测试失败"; exit 1; }
if ! check_elf _ta64 "b700"; then echo "[ERROR] _ta64 不是 aarch64 ELF"; exit 1; fi
if [ "$(wc -c < _ta64)" -lt 500000 ]; then
    echo "[ERROR] _ta64 体积异常，默认静态链接可能未生效"; exit 1
fi
echo "ELF arm64 cross (arm64-tcc.exe) OK: $(wc -c < _ta64) bytes"
rm -f _t.c _t32.exe _tx64 _ta64

echo ""
echo "✓ Windows 交叉编译器构建完成"
echo "  发布目录: $(pwd -W 2>/dev/null || pwd)"
ls -la . sysroot/x86_64/lib sysroot/arm64/lib | head -40
