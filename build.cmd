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
