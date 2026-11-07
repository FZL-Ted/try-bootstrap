# 用 C-only GCC 4.6.4 + musl + EDG 7.0 stage-2 构建 LLVM 9（到 llvm-tblgen）

> **已废弃（2026-11-06）**：本文描述的 `llvm-9-edg-7/` 路线不再维护，该目录已被删除。
> 其中仍被当前流水线使用的 compat 层和 gnu 模式宏表已迁移到 `edg-support/`，当前流水线
> 见 [build-llvm-3.5-by-edg7.0-gcc4.6c.sh](build-llvm-3.5-by-edg7.0-gcc4.6c.sh) 和
> [edg-bootstrap.md](edg-bootstrap.md)。以下内容仅作历史记录，路径均已失效。

- 日期：2026-11-02（CST）
- 工作目录：`/home/tedm/CS/my-proj/my-bootstrap/personal-bootstrap/bootstrap-box/edgcpp-try`
- 构建脚本：[llvm-9-edg-7/build-llvm9-by-edg7.0-gcc4.6.sh](llvm-9-edg-7/build-llvm9-by-edg7.0-gcc4.6.sh)
- 输入文件：`llvm-9-edg-7/files/`（compat 层、driver、宏表）
- 工作/构建目录：`build/llvm-9-edg-7/`
- 相关前置文档：[edg-bootstrap.md](edg-bootstrap.md)（EDG 5.1 → 7.0 stage-1 → stage-2 自举）

## 1. 目标与当前结果

在**只有 C 编译器**的 GCC 4.6.4 + musl 上，用**新脚本构建出的 EDG 7.0 stage-2 前端**
（`build/edg7.0-stage2/edgcpfe`）翻译 LLVM 9.0.1 源码，由 gcc-4.6 编译生成的 C。

本次先构建到 `llvm-tblgen`（LLVM 全量库和 clang 阶段已写进脚本，但在 `exit 0` 之后，
本次不执行）。实测（2026-11-02 20:47–21:22，约 34 分钟）：

| 产物 | 结果 |
| --- | --- |
| EDG 7.0 stage-2 前端 | `build/edg7.0-stage2/edgcpfe`，version 7.0（IA64/Itanium ABI） |
| libc++ 9 | ✅ **33/33** 个 TU，`libc++_ia64.a` 2,806,868 B |
| EDG 7.0 运行时库 | ✅ 51 个对象，`libC_ia64_weak.a` 181,034 B（与 libc++ 重名的 84 个符号已弱化） |
| libc++ 冒烟测试 | ✅ vector/string、iostream+stoi+异常、多 TU 全部通过 |
| **`llvm-tblgen`** | ✅ **14,090,232 B**，`LLVM version 9.0.1` |
| `--print-records X86.td` | ✅ **1,910,183 行**记录，rc=0 |
| 脚本总结果 | ✅ `EXIT=0`，随后按设计在 `exit 0` 处停止 |

与 EDG 5.1 路线相比：

- **不需要 EDG 补丁**：5.1 在 `GlobalISelEmitter.cpp` 上的变参模板 NULL 解引用在 7.0 中已修复；
  7.0 能正常翻译该 TU。
- 7.0 的 `LLVM/ADT/StringExtras.h` 查找 bug 仍在（`"detail" is ambiguous`），所以 driver
  对 LLVM 自身源码仍使用 `--preinclude=StringExtras.h` 的规避。
- EDG 7.0 的 weak/inline 输出仍是 `extern __inline__`，仍需要 `weaken_inline.py` 和
  “内部链接符号去 weak 后重试”的处理。

## 2. 前置条件（只读使用）

| 路径 | 说明 |
| --- | --- |
| `compiler-test/ref-rootfs-gcc4.6-c-only/` | C-only GCC 4.6.4 + musl + binutils |
| `build/edg7.0-stage2/edgcpfe` | EDG 7.0 stage-2 前端（`./build-edgcpp-stage2.sh` 的产物） |
| `build/edg7.0-edg5.1/base/` | EDG 7.0 base：`include/`、`include_c99/` |
| `build/edg7.0-edg5.1/lib/libC.a` | EDG 7.0 运行时库（stage-1 用 EDG 7.0 构建） |
| `llvm-project/` | LLVM 9.0.1 源码 |

宿主只需要 `python3`、`cmake`、`ninja`（构建工具，不参与编译）。全程不联网、不提交 git。

## 3. 目录结构

```
edgcpp-try/
├── build-edg-5.1-by-gcc-4.6-c-only.sh      # EDG 5.1 构建（前置）
├── build-edgcpp-by-edg-5.1.sh              # EDG 7.0 stage-1（前置）
├── build-edgcpp-stage2.sh                  # EDG 7.0 stage-2（前置）
├── edg-bootstrap.md                        # EDG 自举文档（前置）
├── build/
│   ├── edg5.1-gcc4.6c/                     # EDG 5.1 产物
│   ├── edg7.0-edg5.1/                      # EDG 7.0 stage-1（前端/base/libC.a）
│   ├── edg7.0-stage2/                      # EDG 7.0 stage-2（前端）
│   └── llvm-9-edg-7/                       # 本脚本的工作/产物目录
│       ├── edgcpfe                         #   stage-2 前端副本
│       ├── edg/                            #   EDG base（include、include_c99、lib/宏表）
│       ├── compat/                         #   compat 层与 weaken 脚本
│       ├── driver/                         #   edg-cxx / cc46
│       ├── lib/                            #   libc++_ia64.a、libC_ia64_weak.a
│       ├── lcx/ lcxobj/                    #   libc++ 生成的 C/对象
│       ├── tests/                          #   冒烟测试
│       ├── llvm-build/                     #   LLVM CMake/Ninja 构建目录
│       └── log/                            #   全部日志
├── llvm-9-edg-7/
│   ├── build-llvm9-by-edg7.0-gcc4.6.sh     # 构建脚本
│   └── files/
│       ├── compat/{atomic_decls.h,atomic_compat.c,weaken_inline.py}
│       ├── driver/{edg-cxx,cc46}
│       └── predefined_macros.txt           # gnu 模式宏表（843 行）
├── llvm-project/、compiler-test/           # 只读输入
└── llvm-9-edg-7-gcc-4.6c.md                # 本文档
```

## 4. 快速开始

```bash
cd /home/tedm/CS/my-proj/my-bootstrap/personal-bootstrap/bootstrap-box/edgcpp-try
./llvm-9-edg-7/build-llvm9-by-edg7.0-gcc4.6.sh
```

本次脚本在 `llvm-tblgen` 验证后 **`exit 0`**；后续阶段（全量 LLVM 库、clang、stage-2
libc++）已写在 `exit 0` 之后，去掉该行即可继续。

环境变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `REF` | `<root>/compiler-test/ref-rootfs-gcc4.6-c-only` | 参考 rootfs |
| `EDG_STAGE2` | `<root>/build/edg7.0-stage2` | EDG 7.0 stage-2 目录 |
| `EDG_STAGE1` | `<root>/build/edg7.0-edg5.1` | EDG 7.0 stage-1（base/libC.a） |
| `LLVM_SRC` | `<root>/llvm-project` | LLVM 源码 |
| `WORK` | `<root>/build/llvm-9-edg-7` | 工作目录（脚本开头删除重建） |
| `JOBS` | `nproc` | 并行度 |
| `EDG_TIMEOUT` | `3600` | 单 TU 的 EDG 超时（秒），export 给 driver |

## 5. 构建阶段

1. **stage 1：准备 EDG 7.0 stage-2 与 base**：复制 `edgcpfe` 到 `WORK/`，复制
   `build/edg7.0-edg5.1/base/{include,include_c99}` 到 `WORK/edg/`，安装
   `files/predefined_macros.txt` 到 `WORK/edg/lib/`。
2. **stage 2：compat 层**：编译 `atomic_compat.c` 为 `libcompat.a`（`__atomic_*`、
   `__builtin_assume_aligned`）。
3. **stage 3：libc++ 9（33 TU）**：EDG 7.0 `--c++14 --g++ --gnu_version=50000 -tused`
   翻译 → `weaken_inline.py` → gcc-4.6 `-O0` 编译 → `libc++_ia64.a`。
4. **stage 4：EDG 7.0 运行时库弱化**：从 `build/edg7.0-edg5.1/lib/libC.a` 出发，
   对与 libc++ 重名的 84 个符号做 `objcopy -W`，得到 `libC_ia64_weak.a`。
5. **stage 5：driver**：复制 `files/driver/{edg-cxx,cc46}`；driver 通过
   `--edg_base_dir=<WORK>/edg` 指定 7.0 base，并导出 `EDG_ROOT`/`EDG_REF` 供位于
   `build/` 子目录下的 driver 定位工作区与 rootfs。
6. **stage 6：libc++ 冒烟测试**：vector/string、iostream+stoi+`out_of_range`、双 TU。
7. **stage 7：LLVM**：CMake 配置（X86、Release、Ninja）→ 构建 `llvm-tblgen` →
   `--version` 与 `--print-records X86.td` 功能测试。
8. **`exit 0`（本次到此为止）**。
9. **stage 8（写在后面，未执行）**：全量 LLVM 库与工具（`-k 0`）。
10. **stage 9（未执行）**：`-DLLVM_ENABLE_PROJECTS=clang`，构建 stage-1 clang。
11. **stage 10（未执行）**：用 stage-1 clang 构建 stage-2 libc++。

## 6. 与 EDG 5.1 路线的差异

| 项 | EDG 5.1 路线 | EDG 7.0 stage-2 路线 |
| --- | --- | --- |
| 前端 | 需 `edg-5.1-variadic-null-deref.patch` | 无需补丁（7.0 已修复） |
| G++/gnu 模拟 | `--gnu_version=50000` | 相同 |
| 宏表 | 843 行 gnu 表 | 相同文件 |
| 基础头文件 | `$WORK/ia64/{lib,include_c++}` | `$WORK/edg/{lib,include,include_c99}` |
| 内部链接 weak | driver 去 weak 后重试 | 相同，且处理了 EDG 把 weak 属性放在返回类型行、
  函数名在 `#` 行指令之后的情况（否则重试匹配不到） |
| `detail` 歧义 | `--preinclude StringExtras.h` | 仍然需要（7.0 未修复） |

## 7. 已知限制

1. **异常仍是 EDG 自己的 setjmp 实现**（不是 Itanium EH）；与 clang 编译的程序在异常
   路径上不能互操作。完整异常需要 stage-2 libc++/libc++abi（脚本 stage 10）。
2. **stage-1 的 inline 函数被弱化为 out-of-line**：正确性不受影响，clang 会稍慢；
   stage-2 重建后恢复。
3. 本次只验证到 `llvm-tblgen`；全量 LLVM（X86 后端）与 clang 尚未在本路线运行。
4. EDG 7.0 的 tuple/重载解析是否完全修复了 5.1 时代 `RegAllocPBQP.cpp`/
   `CodeViewDebug.cpp` 的问题，需要全量 LLVM 构建来确认（脚本 stage 8）。

## 8. 问题与解决（本路线新增）

| # | 症状 | 根因 | 修法 |
| --- | --- | --- | --- |
| 1 | `invalid EDG_BASE directory` | base 路径多写了一层 `/base`（`WORK/edg` 本身就是 base） | `--edg_base_dir=$WORK/edg` |
| 2 | driver `--version` 报找不到 gcc | driver 位于 `build/llvm-9-edg-7/driver`，按 `dirname` 推导的 ROOT 成了 `build/` | 脚本 export `EDG_ROOT`/`EDG_REF`，driver 优先读取 |
| 3 | `weak declaration ... must be public` 重试无效 | EDG 把 `__attribute__((__weak__))` 放在返回类型行，函数名在 `#` 行指令的下一行，driver 按行匹配不到符号 | 重试时跳过 `#` 行指令再匹配下一行；去掉 weak 后重新编译 |
| 4 | `detail` is ambiguous | EDG 7.0 仍存在该查找 bug | 对 LLVM 源码 `--preinclude=StringExtras.h`（在 `-I` 之后） |

## 9. 验证

```bash
W=build/llvm-9-edg-7
$W/llvm-build/bin/llvm-tblgen --version          # LLVM version 9.0.1
$W/llvm-build/bin/llvm-tblgen --print-records \
  llvm-project/llvm/lib/Target/X86/X86.td \
  -I llvm-project/llvm/include -I llvm-project/llvm/lib/Target/X86 | wc -l   # 1910183
ar t $W/lib/libc++_ia64.a | wc -l                # 33
$W/tests/iostream_eh                             # hello 3 / stoi=42 / caught: vector
```

日志：`build/llvm-9-edg-7/log/`（各 libc++ TU、tests、cmake-configure、tblgen-build、
tblgen-smoke）。

## 10. 下一步

1. 去掉脚本中的 `exit 0`，运行 stage 8（全量 LLVM 库）——预计数小时，需观察新前端问题；
2. stage 9 构建 stage-1 clang；
3. stage 10 用 clang 重建 libc++/libc++abi，替换 EDG 的 setjmp 异常模型；
4. 清理：`build-llvm9-try-1/` 与 `llvm9-build/` 已按计划移除。
