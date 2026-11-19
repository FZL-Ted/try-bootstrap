# 用 EDG 7.0 + 宿主 GCC + musl 构建 LLVM/Clang 3.5

- 日期：2026-11-05（CST，构建跨至 11-06 凌晨）
- 工作目录：`/home/tedm/CS/my-proj/my-bootstrap/personal-bootstrap/bootstrap-box/edgcpp-try`
- 构建脚本：[2-llvm-3.5-by-edg7.0-gcchost.sh](2-llvm-3.5-by-edg7.0-gcchost.sh)
- 工作/构建目录：`build/llvm3.5-edg7.0-gcchost/`
- 相关前置文档：[edg-bootstrap.md](edg-bootstrap.md)、[llvm-9-edg-7-gcc-4.6c.md](llvm-9-edg-7-gcc-4.6c.md)

## 1. 目标与结果摘要

用 **EDG 7.0 C++ 前端**（C++ → C）+ **宿主 GCC 16**（编译生成的 C/链接）
+ **musl**（ref-rootfs 的静态 libc）构建 **LLVM/Clang 3.5.2**。

```
C++ 源码 --(EDG 7.0)--> 生成的 C --(宿主 GCC)--> 目标文件
                                                   静态 musl 链接
```

实测（2026-11-05 23:39 – 2026-11-06 01:25，`-j19`，从空目录完整构建，约 5123 秒）：

| 产物 | 结果 |
| --- | --- |
| libc++ 9（33 TU，EDG 翻译 + 宿主 GCC 编译） | ✅ 33/33，`libc++.a` 2,834,164 B |
| EDG 7.0 运行时（与 libc++ 重叠符号弱化） | ✅ 51 个对象，`libC_weak.a` 181,034 B，84 个重叠符号已弱化 |
| `llvm-tblgen` | ✅ 7,654,936 B，`LLVM version 3.5.2svn`；`--print-records X86.td` 645,804 行 |
| LLVM 3.5 库与核心工具（`llc`/`opt`/`llvm-*`） | ✅ 14 个工具；`llc` 29,531,024 B 静态 |
| `clang` 3.5.2 | ✅ `clang-3.5` 77,619,624 B 静态，`clang version 3.5.2` |
| 驱动冒烟（vector/iostream/异常/多 TU） | ✅ 全部通过（`hello 3`、`stoi=42`、`caught: vector`、`multi-tu 2`） |
| 静态性 / musl / bwrap 验证 | ✅ tblgen/llc/clang 均 static 且无 `NEEDED`；clang 编译的 C 程序静态运行于 bwrap |

> 本次没有使用 GCC 4.6 的 C 后端：LLVM 的 C++ 由 EDG 翻译成 C 后，交给**宿主 GCC**
> 编译；C 库使用 ref-rootfs 的 musl。这样既避开 GCC 4.6 的 C 语言限制，也避免
> glibc 依赖。

## 2. 前置条件（只读使用）

| 路径 | 说明 |
| --- | --- |
| `compiler-test/ref-rootfs-gcc4.6-c-only/` | musl 头文件/静态库（`usr/include`、`usr/lib`）与 binutils；**不需要**其中的 GCC 4.6 C 编译器 |
| `build/edg7.0-edg5.1/edgcpfe` | EDG 7.0 前端（`./build-edgcpp-by-edg-5.1.sh` 的产物） |
| `build/edg7.0-edg5.1/base/` | EDG 7.0 base：`include/`、`include_c99/` |
| `build/edg7.0-edg5.1/lib/libC.a` | EDG 7.0 运行时库（IA64/Itanium ABI） |
| `edg-support/predefined/gnu/predefined_macros.txt` | gnu 模式预定义宏表（843 行） |
| `llvm-project-3.5/{llvm,clang}` | LLVM/Clang 3.5.2 源码 |
| `llvm-project-9.0/libcxx` | libc++ 9 源码与头文件（musl 支持完整） |

宿主需要：`python3`、`cmake`、`ninja`、`gcc`、`ar/nm/objcopy`（优先用 ref-rootfs
的 binutils）、`timeout`、`file/readelf`。全程不联网、不提交 git。

### 为什么用 libc++ 9 而不是 3.5 自带的 libc++

`llvm-project-3.5/libcxx` 完全没有 musl 支持：`__config` 直接 `#include <features.h>`
并使用 `__GLIBC_PREREQ`，`__locale` 也只在 glibc/BSD 分支里可用；直接用 EDG 翻译
会在 `__config` 的 `char16_t/char32_t` 处报错。`llvm-project-9.0/libcxx` 原生支持
`_LIBCPP_HAS_MUSL_LIBC`，并且本仓库早期的 `llvm-9-edg-7` 实验已经用 EDG 7.0 验证过它的
全部 33 个 TU，因此这里复用它。LLVM 3.5 只使用 C++11 子集，与 libc++ 9 兼容。

## 3. 目录结构

```
edgcpp-try/
├── 2-llvm-3.5-by-edg7.0-gcchost.sh   # 构建脚本（自包含）
├── 2-llvm-3.5-by-edg7.0-gcchost.md   # 本文档
├── build-edg-5.1-by-gcc-4.6-c-only.sh # 前置：EDG 5.1
├── build-edgcpp-by-edg-5.1.sh         # 前置：EDG 7.0
├── edg-support/predefined/gnu/predefined_macros.txt
├── llvm-project-3.5/、llvm-project-9.0/、compiler-test/   # 只读输入
└── build/llvm3.5-edg7.0-gcchost/
    ├── edgcpfe                      # EDG 7.0 前端副本
    ├── edg/                         # EDG base（include、include_c99、gnu 宏表）
    ├── src/{llvm,clang}             # 可补丁的源码副本
    ├── lcx/、lcxobj/                # libc++ 生成的 C / 目标文件
    ├── lib/libc++.a                 # C++ 标准库
    ├── lib/libC_full.a              # 原 EDG 运行时
    ├── lib/libC_weak.a              # 重叠符号弱化后的运行时
    ├── driver/edg-cxx、cc-host      # CMake/Ninja 驱动
    ├── weaken_inline.py             # inline/linkonce 处理
    ├── llvm-build/                  # CMake/Ninja 构建树
    ├── tests/                       # 驱动与 clang 冒烟测试
    ├── log/                         # 全部日志
    └── build-info.txt               # 结果摘要
```

## 4. 快速开始

```bash
cd /home/tedm/CS/my-proj/my-bootstrap/personal-bootstrap/bootstrap-box/edgcpp-try
./2-llvm-3.5-by-edg7.0-gcchost.sh
```

默认一直构建到 `clang`。可分阶段运行：

```bash
STOP_AFTER=tblgen ./2-llvm-3.5-by-edg7.0-gcchost.sh   # 只到 llvm-tblgen（约 10 分钟）
STOP_AFTER=llvm   ./2-llvm-3.5-by-edg7.0-gcchost.sh   # 到 LLVM 库与核心工具
JOBS=8            ./2-llvm-3.5-by-edg7.0-gcchost.sh   # 限制并行度
KEEP_WORK=1       ./2-llvm-3.5-by-edg7.0-gcchost.sh   # 复用已有工作目录（增量）
```

### 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `REF` | `compiler-test/ref-rootfs-gcc4.6-c-only` | musl 与 binutils 的 rootfs |
| `EDG70` | `build/edg7.0-edg5.1` | EDG 7.0 前端 / base / 运行时 |
| `LLVM35_SRC` | `llvm-project-3.5` | LLVM 3.5 源码 |
| `LIBCXX9_SRC` | `llvm-project-9.0/libcxx` | libc++ 9 源码 |
| `MACRO_TABLE` | `edg-support/predefined/gnu/predefined_macros.txt` | gnu 宏表 |
| `WORK` | `build/llvm3.5-edg7.0-gcchost` | 工作目录（默认删除重建） |
| `JOBS` | `nproc --ignore=1` | 并行度（**不占满所有核心**） |
| `STOP_AFTER` | `clang` | `tblgen` / `llvm` / `clang` |
| `KEEP_WORK` | `0` | `1` 复用工作目录 |
| `HOST_CC` | `gcc` | 宿主 C 编译器 |
| `EDG_TIMEOUT` | `3600` | 单 TU 的 EDG 翻译超时（秒） |
| `CC_TIMEOUT` | `1200` | 单 TU 的宿主 GCC 编译超时 |
| `LIBCXX_TIMEOUT` | `900` | 单个 libc++ TU 的超时 |
| `CONFIGURE_TIMEOUT` | `1800` | CMake 配置超时 |
| `TBLGEN_TIMEOUT` | `7200` | `llvm-tblgen` 构建超时 |
| `LLVM_TIMEOUT` | `28800` | LLVM 库/工具构建超时 |
| `CLANG_TIMEOUT` | `14400` | clang 构建超时 |

## 5. 构建流程

1. **sanity**：校验所有只读输入；用 `gcc --sysroot=<ref> -static` 编一个 musl
   程序并运行，确认宿主 GCC 真的能静态链接 musl。
2. **stage 1：EDG base**：复制 `edgcpfe`、`base/{include,include_c99}`，安装 843
   行 gnu 宏表；`--version` 必须含 `version 7.0`。
3. **stage 2：libc++ 9**：对 33 个 `libcxx/src/*.cpp`：
   `EDG --c++14 --g++ --gnu_version=50000 -tused` → `weaken_inline.py` →
   `gcc --sysroot + -std=gnu99 -O0` → `ar rcs libc++.a`。
4. **stage 3：EDG 运行时弱化**：求 `libc++.a` 与 `libC.a` 的符号交集，对运行时
   目标文件 `objcopy -W`，重新打包为 `libC_weak.a`（重叠符号以 libc++ 为准，
   其余 EDG 异常/静态初始化符号仍然可用）。
5. **stage 4：驱动**：生成 `driver/edg-cxx`（Python）与 `driver/cc-host`（shell）。
6. **stage 5：源码副本与补丁**：复制 `llvm`、`clang` 到 `WORK/src`，应用
   musl 兼容补丁（见 §8）。
7. **stage 6：驱动冒烟**：vector/string、iostream + `std::stoi` + `out_of_range`、
   双 TU；全部静态 musl 链接并运行。
8. **stage 7：CMake 配置**：Ninja、Release、X86、禁 tests/docs/examples、
   `CMAKE_POLICY_VERSION_MINIMUM=3.5`（CMake 4.x 需要）。
9. **stage 8：里程碑**：
   - `llvm-tblgen` → `--version` 含 3.5.2；`--print-records X86.td`；
   - LLVM 库与核心工具（`llc`、`opt`、`llvm-config`、`llvm-ar` 等）；
   - `clang`。
10. **stage 9：验证**：静态性、`readelf -d` 无 `NEEDED`、用新 clang 静态编译并
    运行 C 程序、clang++ 头文件语法检查、bwrap 隔离运行；写 `build-info.txt`。

每个长操作都带 `timeout`；失败时收集 `FAILED:` 列表和对应日志，脚本以非 0 退出。

## 6. 关键设计决策

### 6.1 驱动：EDG 选项顺序

`edg-cxx` 生成的命令行里 **`-I` 必须排在 `--sys_include` 之前**。实测如果把
`--sys_include` 放在前面，EDG 会找不到宿主 GCC 内部头文件目录里的 `stddef.h`。

### 6.2 不定义 `_LARGEFILE64_SOURCE`

musl 在 `_LARGEFILE64_SOURCE` 下把 `fopen64/fseeko64/ftello64/tmpfile64/stat64/...`
定义成宏。LLVM 3.5 的 `llvm/Target/TargetLibraryInfo.h` 恰好用这些名字做
`enum LibFunc` 的枚举项，于是 EDG 预处理后变成重复声明。驱动只定义 `_GNU_SOURCE`
（保留 `pthread_setname_np` 等 GNU 接口），不定义 `_LARGEFILE64_SOURCE`。
musl 下 LLVM 自己的 JIT 代码对 `stat64` 的引用都在 `#ifdef __GLIBC__` 里，不受影响。

### 6.3 inline / weak

EDG 输出 `extern __inline__`，在 GCC 的 C99 inline 规则下每个 TU 都会产生强定义。
`weaken_inline.py` 去掉 `__inline__` 并加 `__attribute__((__weak__))`，得到
linkonce 语义。两处额外修正：

- `__always_inline__` 必须一起去掉：GCC 拒绝内联 weak 函数，并把它变成硬错误
  （`inlining failed ... function body can be overwritten at link time`）。
- 内链接函数（`static` / 匿名命名空间）不能加 weak。EDG 会把一条声明拆成多行
  并插入 `# line` 指令，因此脚本用“遇 `static` 置位、遇 `; { }` 复位”的逻辑
  声明状态来跟踪；驱动还对 EDG 自己生成的 weak 做错误驱动的清理（见 §8）。

### 6.4 运行时与 libc++ 的重叠

libc++ 与 EDG 运行时都定义 `operator new/delete`、`std::terminate`、typeinfo 等。
链接时把运行时一侧的 84 个同名符号弱化，libc++ 的定义生效，EDG 专有的异常处理
与静态初始化符号继续由 `libC_weak.a` 提供。

### 6.5 静态 musl

宿主 GCC 用 `--sysroot=<ref-rootfs>` 找到 musl 头文件、`crt1.o`、`libc.a`，
链接统一加 `-static`；最终二进制不依赖 glibc，也不依赖动态加载器。

### 6.6 函数对齐：成员函数指针的低比特

EDG 生成的 C 用“成员函数指针结构体 `{f, d}` + `f & 1`”区分虚函数/普通函数
（Itanium ABI 的成员函数指针编码）。`-O1` 下 GCC 默认只做 1 字节函数对齐，
函数可能落在奇数地址，`f & 1` 就会把普通函数误判为虚函数，运行时按 vtable
索引并崩溃（实测表现为 `clang` 解析任意 C 文件时段错误，回溯落在
`Parser::ParseDeclaratorInternal`、`BalancedDelimiterTracker::consumeOpen`）。
因此所有 EDG 生成的 C 统一用 `-falign-functions=16` 编译；正规编译器在需要
成员函数指针时也保证 ≥2 字节对齐。

## 7. 与 `llvm-9-edg-7` 路线差异

| 项 | `llvm-9-edg-7`（GCC 4.6 C 后端） | 本路线（宿主 GCC + musl） |
| --- | --- | --- |
| C 后端 | ref-rootfs 的 C-only GCC 4.6.4 | 宿主 GCC 16 |
| 原子操作 | 需要 `libcompat.a`（`__atomic_*`、`__builtin_assume_aligned`） | 宿主 GCC 自带，不需要 |
| libc | musl（GCC 4.6 目标） | musl（宿主 GCC `--sysroot`） |
| libc++ | libc++ 9 | libc++ 9（相同） |
| 目标 | LLVM 9 到 `llvm-tblgen` | LLVM/Clang 3.5 全量 |
| 驱动 | `files/driver/edg-cxx` | 脚本内生成，新增 weak 清理与 `_LARGEFILE64_SOURCE` 修正 |

## 8. 问题与解决

| # | 症状 | 根因 | 修法 |
| --- | --- | --- | --- |
| 1 | EDG `cannot open source file "stddef.h"` | `--sys_include` 出现在 `-I` 之前，EDG 没有找到宿主 GCC 内部头 | 驱动把 `--sys_include` 放到所有 `-I` 之后 |
| 2 | `"fopen" has already been declared in the current scope` | musl 的 LFS64 宏把 `fopen64` 等展开成已声明函数，撞 LLVM `LibFunc` 枚举 | 只定义 `_GNU_SOURCE`，不定义 `_LARGEFILE64_SOURCE` |
| 3 | `inlining failed in call to 'always_inline' ...` | EDG 输出 `always_inline + weak` | `weaken_inline.py` 同时去掉 `__always_inline__` |
| 4 | `weak declaration of '...' must be public` | EDG 对内链接函数也发 weak；声明跨多行 + `# line` 指令 | 逻辑声明状态跟踪 + 驱动错误驱动回溯删除 weak |
| 5 | `return value type does not match the function type`（`DynamicLibrary.cpp`） | musl 把 `stderr/stdout/stdin` 声明为 `FILE *const`，`&SYM` 是 `FILE *const *` | 源码副本中改为 `return (void *)&SYM` |
| 6 | libc++ 3.5 无法用 musl | `__config` 依赖 glibc `__GLIBC_PREREQ` | 使用 libc++ 9（`_LIBCPP_HAS_MUSL_LIBC`） |
| 7 | clangFrontend 两个 TU 报 `member ... is inaccessible` | EDG 7.0 不允许同一类模板的不同特化互访私有成员（C++11 允许，GCC/clang 接受） | 在 `IntrusiveRefCntPtr.h` 加 `friend class` 声明 |
| 8 | 新构建的 `clang` 解析任意源码时段错误 | `-O1` 下函数 1 字节对齐；EDG 成员函数指针用低比特判定虚函数，奇数地址被误判 | 生成 C 统一加 `-falign-functions=16` |
| 9 | ninja `unknown target 'llvm-ranlib'` | LLVM 3.5 的 `llvm-ranlib` 不是 ninja 目标（CMake 生成符号链接） | 不把 `llvm-ranlib` 列为构建目标 |

## 9. 验证

```bash
W=build/llvm3.5-edg7.0-gcchost
$W/llvm-build/bin/llvm-tblgen --version                 # LLVM version 3.5.2
$W/llvm-build/bin/llvm-tblgen --print-records \
  $W/src/llvm/lib/Target/X86/X86.td \
  -I $W/src/llvm/include -I $W/src/llvm/lib/Target/X86 | wc -l
$W/llvm-build/bin/llc --version                          # 列出 x86 目标
$W/llvm-build/bin/clang --version                        # clang version 3.5.2
file $W/llvm-build/bin/clang-3.5                         # statically linked
readelf -d $W/llvm-build/bin/clang-3.5 | grep NEEDED || echo "no NEEDED"
ar t $W/lib/libc++.a | wc -l                             # 33
$W/driver/edg-cxx $W/tests/vector_string.cpp -o /tmp/x && /tmp/x

# clang 编译 + 宿主 GCC 静态链接（clang 3.5 驱动在 musl sysroot 下找不到 libgcc）
REF=compiler-test/ref-rootfs-gcc4.6-c-only
$W/llvm-build/bin/clang --sysroot=$REF -static -c hello.c -o hello.o
gcc --sysroot=$REF -static hello.o -o hello && ./hello
```

日志在 `build/llvm3.5-edg7.0-gcchost/log/`；摘要与耗时在 `build-info.txt`
（本次验证输出：`llvm-tblgen`/`llc`/`clang` 均 static，clang C 程序、clang++
头文件语法检查、bwrap 隔离验证全部通过）。

## 10. 已知限制

1. **异常模型**：libc++ 由 EDG 编译，异常使用 EDG 的 setjmp 实现，不是 Itanium
   EH；因此用本路线产出的 `clang++` 链接 EDG 版 libc++ 时，异常路径与
   clang 编译的代码不互通。用 clang 重建 libc++/libc++abi 属于后续工作。
2. **clang 的静态链接**：clang 3.5 的驱动在 `--sysroot` 下寻找
   `crtbeginT.o`/`-lgcc`，而 musl rootfs 不含 GCC 安装。当前验证流程是
   “clang 编译（`-c`）+ 宿主 GCC 静态链接”，产物仍是纯静态 musl 程序。
3. **优化级别**：EDG 生成的 C 体积很大，驱动把生成 C 的优化上限压到 `-O1`；
   并强制 `-falign-functions=16`（成员函数指针低比特语义）。
4. 只构建 X86 目标；`libcxxabi`/`libunwind`/`compiler-rt` 不在本路线内。
5. 全量 LLVM/clang 构建耗时以小时计（本次 5123 秒）；失败时脚本保留里程碑
   产物并列出失败 TU。

## 11. 后续

1. 用产出的 clang 重建 libc++（stage-2），替换 EDG 异常模型；
2. 增加 aarch64/riscv 目标；
3. 以本工具链为输入构建 LLVM 9（参考 `build-llvm-9.0-by-llvm-3.5.sh`）。
