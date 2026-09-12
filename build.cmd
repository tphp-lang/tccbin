@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul
REM =============================================================
REM Windows TCC 构建 (MSYS2 MinGW64 gcc + mob 分支 build-tcc.bat)
REM =============================================================

echo === 1. 克隆 TCC 源码 ===
rmdir /s /q tcc 2>nul
set TCC_CLONED=0
for /L %%i in (1,1,3) do (
  if !TCC_CLONED!==0 (
    echo [*] 第 %%i 次尝试克隆 TCC...
    git clone --depth 1 --branch mob https://repo.or.cz/tinycc.git tcc 2>nul && set TCC_CLONED=1
    if !TCC_CLONED!==0 timeout /t 10 /nobreak >nul
  )
)
if !TCC_CLONED!==0 (echo [ERROR] 无法克隆 TCC && exit /b 1)

echo === 2. 编译 TCC ===
cd tcc\win32
call build-tcc.bat
cd ..\..

echo === 3. 验证 ===
if not exist tcc\win32\tcc.exe (echo [ERROR] TCC 编译失败 && exit /b 1)
echo [OK] TCC: tcc\win32\tcc.exe

echo === 4. 修复 kernel32.def（XP 时代导出表过旧，缺 IsWow64Process 等新 API）===
REM mob 分支自带 win32/lib/kernel32.def 仅 776 个导出（XP 时代）。tcc 链接时优先用
REM 该 def 而非真实 System32\kernel32.dll，导致 civetweb 等直接调用 IsWow64Process
REM （XP SP2/Vista 加入）的程序报 "tcc: error: unresolved reference"。
REM 用刚编译好的 tcc.exe 从真实 kernel32.dll 重新生成完整导出表（覆盖式，最稳健）。
if exist "%SystemRoot%\System32\kernel32.dll" (
    tcc\win32\tcc.exe -impdef "%SystemRoot%\System32\kernel32.dll" -o tcc\win32\lib\kernel32.def
    echo [OK] kernel32.def 已由真实 kernel32.dll 重新生成
    findstr /i "IsWow64Process" tcc\win32\lib\kernel32.def >nul && echo [OK] IsWow64Process 已在导出表中 || echo [WARN] IsWow64Process 未出现在导出表
) else (
    echo [WARN] 未找到 %SystemRoot%\System32\kernel32.dll，跳过 def 重生成（仍将使用过旧的 mob 版本）
)
