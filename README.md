# tcc 编译器二进制包

从 [tinycc](https://repo.or.cz/tinycc.git) mob 分支构建的独立 TCC 编译器二进制包，CI 产物见 Actions Artifacts。

## 交叉编译支持

TCC 的目标平台在编译 tcc 自身时由 `TCC_TARGET_*` 宏决定（`-arch` 是被忽略的选项），
交叉编译器是按目标命名的独立二进制，如 `x86_64-win32-tcc`（在 Linux 上跑、生成 Windows PE）。

| 发布包 | 二进制 | 用途 |
|---|---|---|
| tcc-linux-x86_64 | `tcc` | Linux x86_64 native |
| | `x86_64-win32-tcc` | → 64 位 Windows exe（零外部依赖） |
| | `i386-win32-tcc` | → 32 位 Windows exe（零外部依赖） |
| tcc-linux-aarch64 | `tcc` | Linux arm64 native |
| | `x86_64-win32-tcc` | → 64 位 Windows exe（零外部依赖） |
| tcc-win-x86_64 | `tcc.exe` | Windows x64 native |
| | `i386-win32-tcc.exe` | → 32 位 Windows exe（零外部依赖） |
| | `x86_64-tcc.exe` | → Linux x86_64 ELF（默认静态链接，自带 sysroot） |
| | `arm64-tcc.exe` | → Linux arm64 ELF（默认静态链接，自带 sysroot） |
| tcc-macos-aarch64 | `tcc` | macOS arm64 native |

使用约定：**全部位置无关**——支持文件位置基于二进制/启动器所在目录自动解析，
解压到任意路径后可从任意工作目录调用。Linux 包自带 glibc 头文件/CRT/静态库，
容器或精简系统里无需安装 libc6-dev；PE 交叉自带 win32 头文件与导入库；
Windows 包的 ELF 交叉默认静态链接，直接 `x86_64-tcc.exe hello.c -o hello` 即可。
