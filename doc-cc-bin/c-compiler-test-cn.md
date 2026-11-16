# C 编译器综合评测：基线、相互构建与 EDG 5.1（x86_64）

- 日期：2026-11-13 ～ 2026-11-16
- 工作目录：`/home/tedm/CS/my-proj/my-bootstrap/personal-bootstrap/bootstrap-box/Compilers`
- 汇总范围：`cproc-qbe/`、`pcc/`、`tcc/`、`widcc-slimcc/`、`xcc/`；新增 `pairwise/`（四编译器两两互建）与 `edg5.1-try/`（EDG C++ 前端 5.1）
- 原始详细报告：
  - 基线评测：
    - [`cproc-qbe/cproc-report-1.md`](cproc-qbe/cproc-report-1.md)、[`cproc-report-2.md`](cproc-qbe/cproc-report-2.md)、[`cproc-report-3.md`](cproc-qbe/cproc-report-3.md)
    - [`pcc/pcc-testsuite.md`](pcc/pcc-testsuite.md)
    - [`tcc/tcc-testsuite.md`](tcc/tcc-testsuite.md)
    - [`widcc-slimcc/widcc-testsuite.md`](widcc-slimcc/widcc-testsuite.md)、[`widcc-slimcc/slimcc-testsuite.md`](widcc-slimcc/slimcc-testsuite.md)
    - [`xcc/xcc-testsuite.md`](xcc/xcc-testsuite.md)
  - 相互构建：[`pairwise/pairwise-build-report.md`](pairwise/pairwise-build-report.md)
  - EDG 5.1：[`edg5.1-try/edg5.1-build-report.md`](edg5.1-try/edg5.1-build-report.md)

> 本文是横向汇总。每个实验的完整命令、日志路径和逐项分析请以上面的原始报告为准。
>
> 英文版：[`c-compiler-test-en.md`](c-compiler-test-en.md)。
>
> 修订说明：本文由原 `c-compiler-test.md` 扩展而来，新增 §6（四编译器相互构建）与 §7（EDG C++ 前端 5.1），并更名为 `c-compiler-test-cn.md`；英文版为 `c-compiler-test-en.md`。

## 目录

0. 结论速览
1. 环境与评测口径
2. 编译器概览：架构、构建、工具链、标准库、代码量
3. 基线评测 I：c-testsuite 结果与逐项错误
4. 基线评测 II：binutils 2.44 与 toybox 0.8.15
5. 基线评测 III：musl 1.2.5 构建尝试
6. 相互构建：四个编译器两两互建
7. 应用构建：EDG C++ 前端 5.1
8. 综合结论与建议
9. 产物、日志与复现

**阅读建议**

- 只看结论：§0；关注架构/工具链/许可证/代码量：§2。
- 关注基线测试与逐项失败：§3～§5；关注四编译器互建：§6；关注 EDG 5.1：§7。
- 综合判断与修复优先级：§8；复现命令：§9。

**表格约定**：`—` 表示不适用或未做该实验；“未测试”表示本次没有对应数据。

---

## 0. 结论速览

### 0.1 c-testsuite（single-exec，220 项，无 skip）

| 排名 | 编译器 | 宿主通过数 | 通过率 | 宿主失败 |
|---:|---|---:|---:|---|
| 1 | **tcc** | **220 / 220** | **100%** | 无 |
| 2 | **slimcc** | **219 / 220** | **99.5%** | `00206` |
| 3 | **widcc** | **217 / 220** | **98.6%** | `00206`、`00216`、`00219` |
| 4 | **xcc** | **214 / 220** | **97.3%** | `00162`、`00178`、`00202`、`00206`、`00209`、`00216` |
| — | **xcc（宿主 as/ld + glibc）** | **213 / 220** | **96.8%** | 同上 6 项，另加 `00204`（long double/HFA） |
| 5 | **cproc + QBE** | **211 / 220** | **95.9%** | `00141`、`00144`、`00174`、`00204`、`00209`、`00210`、`00213`、`00214`、`00216` |
| 6 | **pcc** | **207 / 220** | **94.1%** | `00143`、`00162`、`00174`、`00200`、`00202`、`00204`、`00206`、`00210`、`00211`、`00212`、`00213`、`00216`、`00219` |

所有报告的 GCC 16.2.0 基线都是 **220 / 220**。

> xcc 的“宿主 as/ld + glibc”是实验模式，不参与默认模式排名；其 c-testsuite 为 213/220。

### 0.2 riscv64 测试（仅有 riscv 构建的四个项目）

| 编译器 | riscv64 结果 | 说明 |
|---|---|---|
| **tcc** | **220 / 220** | tcc 编译 + riscv gcc 链接；tcc + tcc 自举 musl 也是 220/220 |
| **xcc** | **213 / 220** | riscv64 宿主 xcc，qemu 运行；比宿主多 `00204` |
| **cproc + QBE** | **193 / 220** | x86 宿主、目标 riscv64 的交叉编译器；27 个编译错误 |
| **pcc** | **0 / 220** | riscv 版能启动，但后端是未完成的 32 位后端，生成的非 GNU 汇编被 as 拒绝 |
| widcc / slimcc | 未提供 | 上游仅支持 x86-64 Linux |
| **xcc（宿主 as/ld + glibc）** | 不适用 | 该变体仅做 amd64 实验，未在 riscv 上测试 |

### 0.3 musl 1.2.5 构建（未修改源码）

| 编译器 | 编译成功 | 成功率 | `libc.a`/`libc.so` | 最大阻塞 |
|---|---:|---:|---|---|
| **slimcc** | **1284 / 1352** | **95.0%** | 否 | 仅 `_Complex`（68 个） |
| **tcc（x86_64）** | **2525 / 2697 目标** | **93.6%** | 否 | `_Complex` + x86_64 SSE/x87 内联汇编 |
| **tcc（riscv64）** | **1281 / 1351 目标** | **94.8%** | 否 | `_Complex` + 2 个汇编文件 |
| **pcc** | **745 / 1345** | **55.4%** | 否 | register-asm 局部变量（534 个） |
| **widcc** | **722 / 1352** | **53.4%** | 否 | 内联汇编/寄存器变量（557 个） |
| **xcc（x86_64）** | **1117 / 2697 目标** | **41.4%** | 否 | `__builtin_va_list` + 扩展内联汇编 + `_Complex` |
| **xcc（riscv64）** | **566 / 1351 目标** | **41.9%** | 否 | 同上，另加 `__attribute__` |
| **cproc + QBE** | **526 / 1345** | **39.1%** | 否 | 内联汇编（537）+ `long double`（211）+ `_Complex`（68） |
| **xcc（宿主 as/ld + glibc）** | 未测试 | — | — | 该模式未用于 musl 构建 |

### 0.4 binutils 2.44 / toybox 0.8.15

| 编译器 | binutils 2.44 | toybox 0.8.15 |
|---|---|---|
| **tcc** | **完整成功**（282 `.o` + 102 `.lo`，objdump/as/ld） | **成功**（239 applet；需去掉 tcc 不支持的 `--gc-sections`） |
| **slimcc** | **完整成功**（282 `.o` + 102 `.lo`，objdump/as/ld） | **成功**（239 applet） |
| **widcc** | 失败（81/282 `.o`，glibc `_Generic`） | **成功**（239 applet） |
| **xcc（默认 mini libc）** | configure 失败（缺 `ferror`） | 失败（缺 `regex.h`） |
| **xcc（宿主 as/ld + glibc）** | configure 通过，但 make 仍失败（2 个 `.o`） | 并行构建 29 个 `.o` 后失败于 GNU `?:` |
| **cproc + QBE** | 失败（64/282 `.o`，zlib K&R 定义） | 失败（驱动探测 `-xc -`/`--version`） |
| **pcc** | 失败（73/282 `.o`，zlib K&R + `--print-prog-name`） | 失败（`__has_include`） |

GCC 16.2.0 基线：binutils 成功（282 `.o` + 102 `.lo`，objdump 11,106,816 B）；toybox 成功（239 applet，452,768 B）。

### 0.5 代码量速览（物理行 LoC，去除 test/ 等）

| 项目 | 物理行 | 去注释代码行 |
|---|---:|---:|
| pcc | 163,215 | 120,944 |
| tcc | 114,480 | 96,420 |
| xcc | 55,408 | 48,165 |
| cproc + QBE | 27,818 | 24,345 |
| slimcc | 21,843 | 18,492 |

口径与构成见 2.10 节。


### 0.6 探索一：相互构建（四个编译器两两互建）

| 目标 ＼ 来源 | tcc | slimcc | xcc | cproc |
|---|---|---|---|---|
| **tcc** | —（自举对照） | ✅ | ⚠️→✅ | ❌ |
| **slimcc** | ✅ | — | ❌ | ✅（bootstrap 选项） |
| **xcc** | ✅ | ✅ | — | ❌ |
| **cproc + QBE** | ✅ | ✅ | ⚠️*（cproc 成功 / QBE 失败） | — |

- 12 组中 **7 组直接成功、1 组回退后成功、1 组部分成功、3 组失败**。
- 成功产物都通过了 hello + stress，并完成 stage2/gen2 自举；除 slimcc ← cproc 的 `BOOTSTRAP_NO_LDOUBLE` 语义差异外，c-testsuite 结果与原生完全一致。
- 失败根因：cproc 缺 `long double`（2 组）；xcc 前端 bug（1 组，及 QBE 部分）；详见 §6。

### 0.7 探索二：应用构建（EDG C++ 前端 5.1）

| 编译器 | 前端 edgcpfe | C++ 运行库 libC.a | C/C++17/异常 smoke test | 结论 |
|---|---|---|---|---|
| **tcc** | ✅ 63/63 | ✅ 51/51 | ✅ | 完整成功 |
| **slimcc** | ✅ 63/63 | ✅ 51/51 | ✅ | 完整成功 |
| **xcc** | ❌ cc1 段错误 | — | — | 失败 |
| **cproc** | ❌ 不支持 `long double` | — | — | 失败 |

- tcc/slimcc 完整构建出 EDG 5.1 前端与 C++ 运行库，所有 smoke test 通过。
- xcc 的失败是“指向不完整 struct 的指针 typedef”类型补全 bug，可用 4 行合法 C 稳定复现。
- cproc 的失败是 `long double` 未实现；EDG 的 `float_pt.c` 一个文件就有 86 处 `long double`。详见 §7。

### 0.8 一句话总结

- **tcc**：c-testsuite 220/220、riscv64 220/220；musl 只差 C99 复数和少量汇编；12 组互建全部成功，并完整构建 EDG 5.1。
- **slimcc**：c-testsuite 219/220；musl 唯一缺口是 `_Complex`；12 组互建中作为源/目标都可用，并完整构建 EDG 5.1。
- **widcc**：c-testsuite 217/220，但 musl 仅 53.4%，缺内联汇编、寄存器变量、文件作用域 asm、`_Generic` 等。
- **xcc**：c-testsuite 214/220；自带 mini libc + as/ld 的封闭工具链；作为源编译器受头文件缺口和前端 bug 限制，不能构建 slimcc/QBE/EDG。
- **cproc + QBE**：c-testsuite 211/220（基线口径，未加 `-lm`；统一加 `-lm` 后 212/220）；缺 `long double`、inline asm、`_Complex`；`long double` 同时阻断 tcc/xcc 互建和 EDG 5.1。
- **pcc**：c-testsuite 207/220；riscv 后端未完成；musl 55.4%，register-asm 变量是最大单点。


---

## 1. 环境与评测口径

### 1.1 环境

| 项 | 值 |
|---|---|
| 主机 | Linux x86_64，kernel `7.2.12+deb14-amd64`，20 核 |
| 宿主 gcc | gcc `16.2.0`（Debian 16.2.0-3） |
| riscv 交叉 gcc | riscv64-unknown-linux-musl-gcc `16.1.0` |
| riscv sysroot | `/opt/riscv/sysroot`（musl，lp64d/rv64gc；主要是 include + lib，无完整用户态） |
| 模拟器 | qemu-riscv64（cproc 报告为 11.0.0，其余报告为 11.1.2） |
| c-testsuite | commit `5c72756`（2020-03-09），220 个 `tests/single-exec/*.c` |
| musl | 1.2.5 |

### 1.2 c-testsuite 口径

所有报告都遵循 single-exec 规范：

1. 单个 `.c` 文件，入口 `main`；
2. stdout + stderr 必须与 `.expected` 逐字节一致；
3. 退出码必须为 0；
4. 每项限时（各报告收紧为编译 60 s、运行 10–30 s）。

所有报告都**没有使用 skip 列表**，220 项全部实际尝试；GCC 基线均为 220/220。

统一状态定义：

| 状态 | 含义 |
|---|---|
| `PASS` | 编译/链接成功、退出码 0、输出逐字节匹配 |
| `COMPILE_ERROR` | 预处理、编译、汇编或链接任一阶段失败 |
| `RUN_FAIL` | 程序运行退出码非 0（含信号） |
| `OUTPUT_MISMATCH` | 退出码 0，但输出与 `.expected` 不同 |
| `TIMEOUT` | 超过编译/运行时限 |

各家的驱动参数并不完全一致，这是由编译器驱动能力决定的：

| 编译器 | 驱动/链接参数 | 说明 |
|---|---|---|
| cproc | `cproc src -o bin`（未加 `-lm`） | `00174` 因此失败，加 `-lm` 后通过 |
| pcc | `pcc src -o bin`（未加 `-lm`） | 同上 |
| tcc | `-std=c11 -lm` | 原生链接 glibc |
| widcc | `-std=c11 -lm` | 原生链接 glibc |
| slimcc | `-std=c11 -lm` | 原生链接 glibc |
| xcc | `-std=c11`（不加 `-lm`） | xcc 驱动不认 `-lm`，其自带 libc 已含数学函数 |

### 1.3 musl 口径

- cproc、pcc 以 **1345 个 libc 对象**为分母（对应 GCC 最终 `libc.a` 的 1345 个成员）。
- widcc、slimcc 以 musl Makefile 的 **`ALL_OBJS` 1352 个目标**为分母（含 static `.o` 与 shared `.lo` 等）。
- tcc、xcc 的报告按各自构建配置统计：x86_64 同时构建 static + shared 时是 **2697 个编译目标**；`--disable-shared` 时 riscv64 是 **1351 个目标**。
- 因此“总对象数”不能直接横向相加；**百分比和阻塞原因**才是可比的。
- “编译成功”不等于“libc 可用”：只有生成 `libc.a`（或 `libc.so`）并能链接运行程序，才算可用。

### 1.4 相互构建口径（新增）

- 范围：仅 x86_64；四个编译器 tcc、slimcc、xcc、cproc + QBE 两两互建，共 12 个交叉组合；自身构建不计数，仅作对照。
- 源编译器均为原生、由 gcc 构建的版本：
  - tcc：`tcc/build-native/tcc`（0.9.28rc）
  - slimcc：`widcc-slimcc/slimcc/slimcc`
  - xcc：`xcc/build-native/xcc`（0.1.13）
  - cproc：`cproc-qbe/cproc/cproc` + `cproc-qbe/qbe/qbe`
- 目标构建方式：
  - tcc：out-of-tree `configure --cc=<源编译器>` + `make` + `make install`；
  - slimcc：复制源码树后 `make CC=<源编译器>`；
  - xcc：复制源码树后 `make CC=<源编译器> exes`，保留 xcc 自带的 `lib/libc.a`、`lib/crt0.a`；
  - cproc + QBE：分别构建 `qbe` 和 `cproc`，`cproc` 的 `configure` 指向同一源编译器产出的 `qbe`。
- xcc 特殊规则：先使用 xcc 自带的 `cpp/cc1/as/ld` 和 mini libc；失败后回退到“系统 as/ld + 系统头文件 + glibc”（`xcc-sys` 变体）。
- 验证层级：
  1. 产物存在、版本正常；
  2. 编译并运行 hello 与 stress 程序；
  3. stage2 自举（tcc/slimcc/cproc）或 gen2/gen3（xcc）；
  4. 用统一 c-testsuite runner 与原生编译器对比。
- 统一 stress 程序覆盖结构体/联合体/位域/变参/函数指针/长整型/浮点/字符串；c-testsuite 统一使用 `-std=c11 -lm`，xcc 不加 `-lm`（其自带 libc 已含数学函数）。

### 1.5 EDG C++ 前端 5.1 构建口径（新增）

- 输入：`edgcpp-compiler-5.1.tar.gz`；EDG 5.1 前端为 63 个 C 源（`-std=gnu89` 风格，依赖 `-fcommon`），C++ 运行库为 51 个 `lib_src/*.c`。
- 参考脚本：`edgcpp-try/refhost-edg5.1.sh`。
- 步骤：
  1. 生成 `src/err_codes.h`、`src/err_data.h`（`mk_errinfo`）；
  2. 编译 63 个前端源文件，链接 `edgcpfe`；
  3. `--version` 检查；
  4. 翻译 C 程序 → 编译生成 C → 运行；
  5. 用 edgcpfe 将 51 个 C++ 运行库源翻译成 C → 编译 → `ar libC.a`；
  6. 翻译 C++17 程序与异常程序 → 链接 `libC.a` → 运行。
- 方法适配：EDG 翻译 C++ 时使用 musl rootfs 的 `/usr/include`，避免 glibc `bits/floatn.h` 的 `__float128`/`__attribute__((__mode__))`（gcc 基线也会在此失败）；生成 C 的编译使用各编译器默认的 glibc。
- 编译器选项：
  - tcc / slimcc：`-O2 -w -std=gnu89 -fcommon`；
  - cproc：`-O2 -std=gnu89`（cproc 不接受 `-w`、`-fcommon`）。
- 对 xcc 同样先尝试自带工具/库，失败后回退到系统 as/ld + glibc。

---

## 2. 编译器概览：架构、构建、工具链与代码量

### 2.1 版本、许可证与架构总表

| 编译器 | 版本/commit | 许可证 | 上游架构支持 |
|---|---|---|---|
| **cproc + QBE** | cproc `d1c53dd`；QBE `180d2eb`（v1.3-4） | **ISC**（cproc）+ **MIT**（QBE） | x86_64、aarch64、riscv64（由 QBE 后端决定） |
| **pcc** | `8b92dab2`，`1.2.0.DEVEL 20231021` | **BSD/ISC 混合**（含 Caldera 广告条款变体；以文件头为准） | amd64、i386、aarch64、arm、mips、mips64、powerpc、riscv、sparc64、vax 等多后端；**riscv 后端未完成 64 位改造** |
| **tcc** | `2be0218b`，`0.9.28rc` | **LGPL-2.1**（另有 `RELICENSING` 再许可文件，见下） | i386、x86_64、arm、aarch64、riscv64（源码另有 c67 后端） |
| **widcc** | `3d8385c5` | **MIT** | x86-64 Linux（glibc 2.28+） |
| **slimcc** | `2388c399` | **MIT** | x86-64 Linux |
| **xcc** | `83c51319`，`0.1.13` | **MIT** | x86-64、aarch64、riscv64、wasm |

> 许可证依据各仓库的 `LICENSE`/`COPYING`：cproc 为 ISC、QBE 为 MIT、pcc 为 BSD/ISC 混合（`LICENSE.md` 说明以文件头为准）、tcc 为 LGPL-2.1（另有 `RELICENSING`，见下）、widcc/slimcc/xcc 为 MIT。构建状态见 2.8 节。
>
> **tcc 的 `RELICENSING` 说明**：官方 README 与 `COPYING` 仍声明 tcc 采用 LGPL-2.1，源码头也仍是“LGPL version 2 or later”。仓库同时包含 `RELICENSING` 文件，其中列出的作者同意按 MIT 风格条款再许可 TinyCC（包括其历史贡献）。但该名单并非全票：Daniel Glöckner 对 `arm-gen.c` 投 NO（对其他文件 YES），`tiny_libmaker.c`（Timo VJ Lähde）、`tcccoff.c`/`c67-gen.c`（TK）仍为 `?`。因此本文仍把整个 tcc 标注为 **LGPL-2.1**，不能视为纯 MIT；只有明确获准的部分才可按 `RELICENSING` 条款处理。

### 2.2 cproc + QBE

**架构**：cproc 是 QBE 的前端，目标架构由 QBE 决定。cproc README 说明所有 QBE 支持的后端都应可用（当前 x86_64、aarch64、riscv64），其 CI 覆盖 `x86_64-linux-musl/gnu`、`aarch64-linux-musl/gnu`、`riscv64-linux-gnu`。本次实际验证了 x86_64 宿主和 riscv64 目标。

**宿主构建**：

```sh
cd qbe && make -j20 && cd ..
cd cproc && ./configure --with-qbe="$PWD/../qbe/qbe" && make -j20
```

产物：

```text
qbe/qbe          669,384 B
cproc/cproc       50,624 B  (驱动)
cproc/cproc-qbe  291,096 B  (前端)
```

**riscv64 的两种构建**：

- **方案 A**：用 riscv64-unknown-linux-musl-gcc 编译 QBE/cproc 本体，得到 riscv64-musl 可执行文件；用“手工流水线”（交叉 cpp → qemu 中的 cproc-qbe → qemu 中的 qbe → 交叉 as/ld）验证了它能生成正确的 riscv64 程序。但完整驱动依赖目标机上的原生 `cpp/as/ld/qbe`，当前 sysroot 没有用户态，qemu-user 会把外部工具解析成宿主 x86 程序，因此无法在 qemu 下跑完整原生驱动。
- **方案 B**：构建“x86_64 宿主、riscv64-unknown-linux-musl 目标”的交叉编译器，可直接在宿主上编译 riscv64 程序并在 qemu 中运行。c-testsuite 的 193/220 就是用这个方案跑的。

### 2.3 pcc

**架构**：源码树包含非常多的后端（`arch/` 下有 amd64、i386、aarch64、arm、m68k、mips、mips64、powerpc、riscv、sparc64、vax、pdp10、pdp11 等）。但本次只验证了 amd64；riscv 后端是未完成的 32 位实现（`SZLONG`/`SZPOINT` 固定 32 位，汇编输出使用 `subi`、`assign`、`;` 注释等非 GNU 语法）。

**宿主构建**：

```sh
mkdir build-host install-host && cd build-host
../pcc/configure --prefix="$PWD/../install-host"
make -j20 && make install
```

结果：成功，29 条警告、0 错误。产物：

```text
install-host/bin/pcc      36,784 B   (驱动)
install-host/libexec/ccom 470,304 B  (C 编译器本体)
install-host/libexec/cpp   64,792 B
```

为了真正能编译/链接程序，报告还补齐了 pcc-libs 缺失的运行时依赖（不改变测试语义）：

- 空 `libpcc.a`；
- GCC 的 `crtbegin.o`/`crtend.o` 等启动对象；
- GCC 私有头（`stddef.h`、`stdarg.h`、`float.h` 等）。

**riscv64 构建**：修改 8 个文件（configure/cconfig/Makefile/arch/riscv 等）后，用 riscv64 gcc 成功构建并可在 qemu 下启动；但生成的目标代码是 32 位模型和非 GNU 汇编语法，GNU as 无法接受，因此只是一个“能启动的 riscv 二进制”，不是可用的 riscv64 编译器。

### 2.4 tcc

**架构**：README 明确说明生成 i386、x86_64、arm、aarch64、riscv64 的机器码；源码树里另有 c67 后端。本次验证 x86_64 与 riscv64。

**宿主构建**（out-of-tree）：

```sh
mkdir build-native && cd build-native
../tinycc/configure --cc=gcc --prefix="$PWD/../install-native" -q
make -j20 && make install
```

产物：`install-native/bin/tcc`，381,600 B，0 警告。

**riscv64 构建**：

```sh
../tinycc/configure --cross-prefix=riscv64-unknown-linux-musl- \
  --cpu=riscv64 --config-musl --prefix=... \
  --sysincludepaths='{B}/include:/opt/riscv/sysroot/include' \
  --libpaths='{B}:/opt/riscv/sysroot/lib:/opt/riscv/sysroot/usr/lib' \
  --crtprefix=/opt/riscv/sysroot/lib \
  --elfinterp=/lib/ld-musl-riscv64.so.1
make -j20 tcc
make -C lib TCC=work/riscv-tcc.sh XTCC=work/riscv-tcc.sh
```

产物：`install-riscv64/bin/tcc`，481,528 B；`install-riscv64/lib/tcc/libtcc1.a`，65,892 B。

关键点：`make` 默认会用刚构建的 tcc 生成 `libtcc1.a`；由于没有 riscv binfmt，必须用 `qemu-riscv64 -L /opt/riscv/sysroot` 包装器运行它。

### 2.5 widcc

**架构**：README 明确是 glibc 2.28+ 的 x86-64 Linux 专用，没有多架构后端。

**构建**：

```sh
cd widcc
ln -s platform/linux-glibc-generic.c platform.c
make clean && make -j20 CC=gcc
```

产物：`widcc/widcc`，219,768 B，x86-64 PIE；构建无警告。

### 2.6 slimcc

**架构**：与 widcc 同源，README 同样定位 x86-64 Linux；没有独立的多架构后端。

**构建**：

```sh
cd slimcc
ln -s platform/linux-glibc-generic.c platform.c
make clean && make -j20 CC=gcc
```

产物：`slimcc/slimcc`，467,912 B；使用 `-O3 -flto=auto`，链接 jemalloc；构建无错误、无警告。

### 2.7 xcc

**架构**：README 明确支持 x86-64、aarch64、riscv64、wasm；本次验证 x86_64 与 riscv64。

**宿主构建**：

```sh
rsync -a --exclude .git xcc/ build-native/
cd build-native && make -j20
```

产物：`xcc` 205,600 B、`cc1` 1,324,200 B、`cpp` 353,160 B、`as` 636,448 B、`ld` 343,376 B；`lib/libc.a` 由 xcc 自己构建。

**riscv64 的两种构建**：

- 宿主运行的 riscv64 交叉 xcc：`make ARCHTYPE=riscv64 PLATFORM=posix -j20`，产物 `build-riscv64-cross/xcc`（205,696 B），用于生成 riscv64 版 libc/crt0。
- riscv64 宿主的 xcc：用 riscv64 gcc 编译 `exes`，产物 `.xcc.real` 169,824 B、`.cc1.real` 1,421,608 B 等；库从交叉构建复制。

构建 riscv 宿主版时处理了 3 个兼容问题：

1. 增加 `-D_POSIX_C_SOURCE=200809L`，让 musl 头文件声明 `getline`；
2. xcc 原本假设 RISC-V 工具链“没有 getline、只有 `__getline`”，与 musl 相反；在构建副本中把 guard 改为 `__riscv && !__XCC && !__linux__`；
3. musl 的 `elf.h` 缺少 `EF_RISCV_RVC`、`EF_RISCV_FLOAT_ABI_DOUBLE`、`SHT_RISCV_ATTRIBUTES`，通过编译参数补定义。

此外，xcc 用 `argv[0]` 的目录定位 `cpp/cc1/as/ld`；riscv 版不能直接执行这些子工具，因此为五个可执行文件各放一个 qemu 包装器，并用 `qemu-riscv64 -0` 把 guest 的 `argv[0]` 固定为包装器路径，保证 xcc 的路径前缀计算正确。

### 2.8 构建对比

| 编译器 | 宿主构建 | riscv 构建 | 构建额外步骤 | 二进制规模（主驱动） |
|---|---|---|---|---:|
| cproc + QBE | 成功 | 原生组件 + 交叉编译器均成功 | QBE 单独构建 | 50,624 B（+ QBE 669,384 B） |
| pcc | 成功（29 警告） | 成功但后端不可用 | 补 pcc-libs 运行时、8 处源码补丁 | 36,784 B（ccom 470,304 B） |
| tcc | 成功（0 警告） | 成功（可用） | qemu 包装器构建 libtcc1 | 381,600 B / 481,528 B |
| widcc | 成功（0 警告） | 不支持 | `platform.c` 链接 | 219,768 B |
| slimcc | 成功（0 警告） | 不支持 | `platform.c` 链接 | 467,912 B |
| xcc | 成功（0 警告） | 成功（可用） | 3 处兼容处理 + qemu 子工具包装器 | 205,600 B / 169,824 B |

> xcc 的“宿主 as/ld + glibc”是使用模式实验，不是编译器本体的另一种构建；它不列入本表，结果见 4.5。

### 2.9 工具链与标准库速查

#### （1）提供的二进制工具

| 编译器 | 提供的可执行文件/库 | 是否自带 as/ld | 备注 |
|---|---|---|---|
| cproc + QBE | `cproc`（驱动）、`cproc-qbe`（C 前端）、`qbe`（后端） | 否 | 运行时需要外部 `cpp`、`as`、`ld`；QBE 只负责生成汇编 |
| pcc | `pcc`、`pcpp`、`p++`（驱动），`ccom`、`cxxcom`（C/C++ 编译器本体），`cpp` | 否 | 使用宿主 GNU `as`/`ld`；`pcc-libs` 不在此仓库 |
| tcc | 单个 `tcc`（预处理+编译+汇编+链接一体）、`libtcc.a`（可嵌入 API）、`libtcc1.a`（编译器运行时） | **是**（内置） | 自带 `include/`（stddef/stdarg/float 等）；`-run` 可直接 JIT 运行 |
| widcc | 单个 `widcc`、`widcc_headers/` | 否 | 使用宿主 GNU `as`/`ld` |
| slimcc | 单个 `slimcc`、`slimcc_headers/` | 否 | 使用宿主 GNU `as`/`ld` |
| xcc | `xcc`（驱动）、`cpp`、`cc1`、`as`、`ld`；`lib/crt0.a`、`lib/libc.a`、`include/` | **是**（自带） | 完整自带工具链，不调用宿主 as/ld |

#### （2）自带标准库/头文件

| 编译器 | 是否自带完整 C 标准库 | 实际使用的 libc | 自带头文件/运行时 |
|---|---|---|---|
| cproc + QBE | 否 | 宿主 glibc（或目标 sysroot 的 musl） | 无 libc 头文件；依赖目标系统头文件 |
| pcc | 否 | 宿主 glibc | 无完整 libc；`pcc-libs` 提供 `libpcc`/启动辅助（本次用空 `libpcc.a` 补齐） |
| tcc | 否 | 宿主 glibc；riscv 版可配置 `/opt/riscv/sysroot` 的 musl | `include/` 提供 freestanding 头文件，`libtcc1.a` 提供编译器运行时，不是 libc |
| widcc | 否 | 宿主 glibc | `widcc_headers/`（辅助头文件），无 libc |
| slimcc | 否 | 宿主 glibc | `slimcc_headers/`（辅助头文件），无 libc |
| xcc | 否（mini libc，不完整） | 默认使用自带 `lib/libc.a`，不使用宿主 libc | 自带 `include/` + `libc.a` + `crt0.a`；缺 `regex.h`、`ferror` 等 |

> 结论：只有 **xcc** 是“自带 mini libc + 自带 as/ld”的封闭工具链；tcc 自带 as/ld 和运行时，但程序仍链接宿主/目标 libc；其余编译器均依赖宿主 GNU as/ld 和宿主 libc。没有任何一个项目自带完整的 C 标准库。xcc 的“宿主 as/ld + glibc”只是第 4.5 节的实验模式，不属于默认工具链。



---

### 2.10 代码量 LoC

统计口径：

- 统计后缀 `.c`、`.h`、`.S`、`.s`、`.y`、`.l`；
- 排除名字以 `test` 开头的目录（`test/`、`tests/`、`*_test/` 等）、`examples/`、`doc/`、`.git`、`build*/`、`obj/`、`install*/`；
- “物理行”为文本行数（Python `splitlines()`；与 `wc -l` 的差异仅来自末尾无换行的文件，每文件最多 1 行）；“去注释代码行”用简单正则去除 `/* ... */` 与 `// ...` 后统计非空行（不是 cloc 的精确语义，仅供横向比较）；
- pcc 按当前工作区源码统计（含本次 riscv 实验的 8 处补丁）；cproc+qbe 为两个仓库合并；不包含测试、示例、文档和第三方构建产物。
- 统计脚本：[`work/count_loc.py`](work/count_loc.py)。

| 项目 | 文件数 | 物理行（LoC） | 非空行 | 去注释代码行 | 主要构成 |
|---|---:|---:|---:|---:|---|
| **pcc** | 221 | **163,215** | 143,916 | 120,944 | `arch/` 85,873（17 个后端）+ `cc/` 44,497 + `mip/` 11,987 + `f77/` 12,392 等 |
| **tcc** | 166 | **114,480** | 103,562 | 96,420 | 核心 `.c` 63,313 + `.h` 48,025；其中 `win32/` 头文件约 36,618 行 |
| **xcc** | 382 | **55,408** | 49,557 | 48,165 | `src/` 47,985（含 cpp/cc1/as/ld/wcc）+ `libsrc/` 5,814（mini libc）+ `include/` 1,609 |
| **cproc + QBE** | 69 | **27,818** | 25,602 | 24,345 | cproc 8,962 + QBE 18,856（QBE 含 `minic/` 2,635、`tools/` 420） |
| ├ cproc | 26 | 8,962 | 8,262 | 8,011 | 前端、驱动、QBE IL 生成 |
| └ QBE | 43 | 18,856 | 17,340 | 16,334 | amd64/arm64/rv64 后端、parser、minic、tools |
| **slimcc** | 51 | **21,843** | 18,759 | 18,492 | 编译器本体 + `slimcc_headers/` + `platform/` |

说明：

- pcc 的代码量最大，主要因为 `arch/` 下有大量历史架构后端；若只看 `arch/` 之外的部分，仍有 77,342 物理行。
- tcc 的 114,480 行里有约 36,618 行是 `win32/` 下的 Windows API 头文件；剔除后约 77,862 行。
- xcc 的 55,408 行里包含自己的 mini libc（`libsrc/`，5,814 行）和 target 头文件（`include/`，1,609 行），这是它“自带 libc”路线的一部分。
- cproc + QBE 的 27,818 行是两者合并；其中 QBE 的 `minic/` 是小型的测试用 C 编译器，`tools/` 是辅助工具，若只算 QBE 核心可再减约 3,000 行。
- slimcc 的 21,843 行不包含 `test/`；同源的 widcc 未在本次统计范围内。
- 按物理行排序：**pcc（163,215） > tcc（114,480） > xcc（55,408） > cproc+QBE（27,818） > slimcc（21,843）**。

## 3. 基线评测 I：c-testsuite 结果与逐项错误

> **本节要点**：tcc 220/220；slimcc 219/220；widcc 217/220；xcc 214/220（宿主 as/ld 变体 213/220）；cproc+QBE 211/220；pcc 207/220。失败主要集中在编译期，而不是运行期输出错误。

### 3.1 总表

| 编译器 | PASS | COMPILE_ERROR | RUN_FAIL | OUTPUT_MISMATCH | 其他 | 总计 |
|---|---:|---:|---:|---:|---:|---:|
| tcc | 220 | 0 | 0 | 0 | 0 | 220 |
| slimcc | 219 | 0 | 0 | 1 | 0 | 220 |
| widcc | 217 | 1 | 1（段错误） | 1 | 0 | 220 |
| xcc（x86_64） | 214 | 4 | 0 | 2 | 0 | 220 |
| xcc（宿主 as/ld + glibc） | 213 | 4 | 0 | 3 | 0 | 220 |
| cproc + QBE | 211 | 9 | 0 | 0 | 0 | 220 |
| pcc | 207 | 8 | 4 | 1 | 0 | 220 |

### 3.2 cproc + QBE：9 个失败（全部在编译/链接阶段）

| # | 用例 | tags | 阶段 | 诊断/现象 | 根因 |
|---:|---|---|---|---|---|
| 1 | `00141` | portable c89 needs-cpp | QBE codegen | `slot %.1 is read but never stored to` | 测试读取未初始化变量（UB）；QBE 的 SSA 校验拒绝 |
| 2 | `00144` | portable c89 | cproc 编译 | `assignment to pointer discards qualifiers` | 丢弃 `const` 属于约束违反；cproc 报 error，GCC 只警告 |
| 3 | `00174` | portable c99 needs-libc needs-cpp | 链接 | `undefined reference to 'sin'` | 驱动默认不链接 `-lm`；加 `-lm` 后输出完全一致 |
| 4 | `00204` | portable c99 needs-libc needs-cpp | codegen | `long double is not yet supported` | cproc 未实现 `long double`（size 16） |
| 5 | `00209` | portable c89 | cproc 编译 | `too many arguments for function call` | cproc 采用 C23 语义：`()` 表示“无参数” |
| 6 | `00210` | portable c89 needs-cpp | cproc 编译 | `GNU attribute 'packed' is not supported here` | GNU attribute 出现在 union 定义末尾/抽象声明符中 |
| 7 | `00213` | portable c89 | cproc 编译 | `expected primary expression` | GNU 语句表达式 `({ ... })` 未实现 |
| 8 | `00214` | portable c89 | cproc 编译 | `expected primary expression` | 同上 |
| 9 | `00216` | portable needs-libc needs-cpp | cproc 编译 | `no type in struct member declaration` | 零成员 `struct {}`（GNU 扩展）未支持 |

分类：已知语言特性缺失 4（`00204`、`00213`、`00214`、`00216`）；GNU attribute 位置 1（`00210`）；C23 语义冲突 1（`00209`）；严格诊断 1（`00144`）；测试依赖 UB 1（`00141`）；缺 `-lm` 1（`00174`）。

> 结论：cproc 没有运行失败或输出不匹配；9 个失败都不是“编译成功但结果错”。

### 3.3 pcc：13 个失败

| # | 用例 | tags | 阶段 | 诊断/现象 | 根因 |
|---:|---|---|---|---|---|
| 1 | `00143` | portable c89 needs-cpp | 编译 | `invalid function definition` / `syntax error` | Duff's device：case 标签嵌在 do-while 内 |
| 2 | `00162` | portable c99 needs-cpp | 编译 | `bad qualifier` | C99 数组形参限定符 `[const 5]`/`[static 5]`/`[restrict 5]` |
| 3 | `00174` | portable c99 needs-libc needs-cpp | 链接 | `undefined reference to 'sin'` | 驱动不默认链接 `-lm`；加 `-lm` 后通过 |
| 4 | `00200` | portable c89 needs-libc needs-cpp | 运行 | `46 test(s) failed`，如 `((short)((1))) -4 4` | 左移结果类型/符号错误：窄有符号类型提升后被当作 unsigned |
| 5 | `00202` | portable c89 needs-libc needs-cpp | 编译 | `syntax error` | `##` 与空宏参数的 placemarker 语义错误 |
| 6 | `00204` | portable c99 needs-libc needs-cpp | 输出 | long double 返回 `0.0`；HFA 变参损坏 | long double 返回值 / HFA 可变参数 ABI |
| 7 | `00206` | portable c89 needs-libc needs-cpp | 运行 | 输出 `111/222/333/333/333`，退出码 12 | `#pragma push_macro/pop_macro` 未实现 + main 隐式返回未处理 |
| 8 | `00210` | portable c89 needs-cpp | 编译 | `lvalue required` + ICE | GNU attribute 位于抽象声明符 `int(ATTR *)(void)` |
| 9 | `00211` | portable c99 needs-cpp | 运行 | 输出正确 `n+1 = 15`，退出码 9 | main 无 `return` 时未按 C99 返回 0，返回了 printf 的 9 |
| 10 | `00212` | portable c89 needs-libc needs-cpp | 运行 | 输出正确 `Ok`，退出码 3 | 同上，返回了 printf 的 3 |
| 11 | `00213` | portable c89 | 编译 | `operands of : have incompatible types` | GNU 语句表达式未实现 |
| 12 | `00216` | portable needs-libc needs-cpp | 编译 | `major internal compiler error` | 空 struct + 复合字面量全局初始化（GNU 扩展） |
| 13 | `00219` | portable c89 needs-libc needs-cpp | 编译 | `duplicate type in _Generic` | `_Generic` 对 `int`/`const int` 兼容类型的去限定处理与 GCC 不同 |

### 3.4 tcc：0 个失败

tcc 宿主构建 **220/220**。覆盖了宏/预处理、初始化器、位域、浮点、变参、TLS、`setjmp`、内联汇编字符串、复合字面量、`_Generic`、`#pragma push_macro` 等；widcc 失败的 `00178`/`00206`/`00216`/`00219` 在 tcc 下全部通过。

### 3.5 widcc：3 个失败

| # | 用例 | 阶段 | 现象 | 根因 |
|---:|---|---|---|---|
| 1 | `00206` | 输出不匹配 | 期望 `111,222,333,222,111`，实际 `111,222,333,333,333` | `#pragma push_macro/pop_macro` 被整行丢弃 |
| 2 | `00216` | 运行段错误（SIGSEGV） | 调用全局复合字面量里的函数指针时跳到地址 0 | 全局初始化器 `write_gvar_data()` 不处理 `init->expr`，复合字面量中的重定位丢失 |
| 3 | `00219` | 编译错误 | `implicit declaration of a function`（`_Generic(...)`） | widcc README 明确移除 `_Generic`（以及其他 C11 特性） |

补充：`00216` 已用最小复现确认是真实代码生成 bug，不是测试问题；`00206` 是 MSVC/GCC 扩展缺失；`00219` 是设计上移除的标准特性。

### 3.6 slimcc：1 个失败

| # | 用例 | 阶段 | 现象 | 根因 |
|---:|---|---|---|---|
| 1 | `00206` | 输出不匹配 | 期望 `111,222,333,222,111`，实际 `111,222,333,333,333` | 与 widcc 相同：`#pragma push_macro/pop_macro` 未实现 |

slimcc 相对 widcc 修复了 `00216`（全局复合字面量重定位）并实现了 `00219` 的 `_Generic`。

### 3.7 xcc：6 个宿主失败 + riscv 额外 1 个

| # | 用例 | tags | 阶段 | 诊断/现象 | 根因 |
|---:|---|---|---|---|---|
| 1 | `00162` | portable c99 needs-cpp | 编译 | `expression expected` / `cannot dereference raw type` | 不支持 `int x[const *]` 的 VLA `[*]` 形参 |
| 2 | `00178` | portable c89 needs-libc needs-cpp | 输出不匹配 | `sizeof(!a)` 输出 1，期望 4 | `!`/`==` 的结果类型是 1 字节，不是标准要求的 `int` |
| 3 | `00202` | portable c89 needs-libc needs-cpp | 编译 | `lvalue expected`（`60 ++ 3`） | 宏 token paste 产生 `+ +` 后，xcc 输出时没插入空格，被词法合并成 `++` |
| 4 | `00206` | portable c89 needs-libc needs-cpp | 输出不匹配 | 同上 `333/333` | `#pragma push_macro/pop_macro` 未实现 |
| 5 | `00209` | portable c89 | 编译 | `')' expected` | 不支持函数类型形参 `int f2(int (int x), int)` |
| 6 | `00216` | portable needs-libc needs-cpp | 编译 | `']' expected` | 不支持 GNU range designator `[1 ... 5]` |
| +1 | `00204` | portable c99 needs-libc needs-cpp | riscv 输出不匹配 | 变参结构体/HFA 数据损坏 | riscv64 变参/HFA 调用约定实现错误（x86_64 通过） |

`00178` 的最小复现：

```c
char a = 0;
printf("%d %d\n", (int)sizeof(!a), (int)sizeof(a==1));
/* xcc: 1 1；gcc: 4 4 */
```

`00202` 的最小复现：

```c
#define Q(A,B) A ## B+
jim = 60 Q(+,)3;   /* 应为 60 + + 3 → 63 */
/* xcc 预处理输出成 60 ++ 3，报 lvalue expected；gcc 输出 63 */
```

> 宿主 as/ld + glibc 变体另有 213/220：失败集合为上述 6 项再加 `00204`（glibc 的 long double/HFA ABI）。

### 3.8 riscv64 结果

#### cproc + QBE（方案 B 交叉编译器）：193 / 220

失败 **27** 个，全部为 COMPILE_ERROR，无运行失败、无输出不匹配：

| 类别 | 数量 | 用例 |
|---|---:|---|
| QBE rv64 后端 `extern with offset` 限制 | 18 | `00024`、`00047`、`00048`、`00049`、`00050`、`00090`、`00091`、`00092`、`00115`、`00146`、`00147`、`00148`、`00151`、`00163`、`00176`、`00195`、`00205`、`00217` |
| `long double`（musl 头文件触发） | 2 | `00174`、`00204` |
| 与宿主重合的失败 | 7 | `00141`、`00144`、`00209`、`00210`、`00213`、`00214`、`00216` |

根因：cproc HEAD 对所有外部链接全局变量输出 QBE `extern` 标记，而 QBE rv64 后端不支持“外部符号 + 偏移”。报告做了“去掉 `extern` 标记”的因果实验，结果回到 **211/220**，与宿主完全一致，证明这 18 个失败都是同一个接口问题。

#### pcc：0 / 220

riscv 版 pcc 能启动，但无法生成可被 GNU as 接受的 riscv64 代码：

| 类别 | 数量 | 现象 |
|---|---:|---|
| GNU as 拒绝 pcc 生成的汇编 | 146 | `unrecognized opcode 'subi ...'`、`unrecognized opcode 'assign zero'`、`junk at end of line ... '4'` |
| pcc 自带 cpp 在 qemu 下崩溃 | 64 | `qemu: uncaught target signal 11 (Segmentation fault)`（带系统头文件的测试） |
| 前端/代码生成诊断 | 10 | `Cannot generate code, node ... op OREG/SCONV/= `，以及 `00162`/`00210`/`00213` 的同类错误 |

根因：riscv 后端固定 32 位类型模型、输出非 GNU 汇编语法，且 `cpp` 在 qemu 下存在崩溃问题。

#### tcc：220 / 220（三种口径）

| 方式 | 结果 | 说明 |
|---|---:|---|
| tcc 编译（`-c`）+ riscv gcc 链接 | **220/220** | 只测 tcc 的编译/代码生成，链接交给 GNU ld |
| tcc 编译 + tcc 自己构建的 musl 静态链接 | **220/220** | tcc 的完整自举环境 |
| tcc 自己链接 `/opt/riscv/sysroot` 的 GCC 版 musl | **0/220** | 全部 LINK_ERROR：`Unknown relocation type for got: 26/27/28` |

第三种不是测试失败，而是 tcc riscv64 链接器不支持 GCC 生成的绝对重定位（`R_RISCV_HI20`/`LO12_I`/`LO12_S`）；tcc 自己产生的目标文件可以正常链接。

#### xcc：213 / 220

宿主 6 个失败中的 6 个在 riscv 上同样失败，另外多一个 `00204`：

- `00204` 的 riscv 输出差异集中在 `va_arg` 取结构体/HFA 时，例如：

```diff
 stdarg:
-ABCDEFGHI ABCDEFGHI ABCDEFGHI ABCDEFGHI ABCDEFGHI ABCDEFGHI
+ABCDEFGHI ABCDEFGHI ABCDEFGHI @ I2 I
```

说明 xcc 的 riscv64 变参/HFA 调用约定仍有实现缺陷。

#### riscv 测试横向对比

| 编译器 | PASS | 失败阶段 | 结论 |
|---|---:|---|---|
| tcc | 220 | —（纯 tcc 链接时全部 link error） | 编译器可用；链接器不兼容 GCC 目标文件 |
| xcc | 213 | 4 编译 + 3 输出不匹配 | 编译器基本可用，riscv ABI 有 1 个额外 bug |
| cproc + QBE | 193 | 27 编译错误 | 前端/后端可用；QBE rv64 的 extern+offset 缺口 |
| pcc | 0 | 146 汇编 + 64 cpp 崩溃 + 10 前端 | riscv 后端未完成 |

---

## 4. 基线评测 II：binutils 2.44 与 toybox 0.8.15

> **本节要点**：只有 tcc、slimcc 能完整构建 binutils 和 toybox；widcc 只能构建 toybox；xcc 的宿主 as/ld 变体能让 binutils configure 通过，但仍无法完成构建。

### 4.1 构建口径

两个包都只用**宿主 x86_64** 编译器尝试；没有做 riscv 交叉构建。binutils 使用统一配置：

```sh
../work/binutils-2.44-src/configure \
  --disable-nls --disable-werror --disable-gdb --disable-sim \
  --disable-gprof --disable-gprofng --disable-gold --disable-shared \
  --build=x86_64-pc-linux-gnu --host=x86_64-pc-linux-gnu
CFLAGS=-O0 make -k -j4
```

toybox 使用默认 `defconfig`：

```sh
make defconfig
make -j4 CC=<compiler>
```

构建目录分别位于各编译器项目内（`<project>/binutils-2.44/`、`<project>/toybox-0.8.15/`；widcc/slimcc 带前缀）。

### 4.2 binutils 2.44 结果

| 编译器 | configure | make | 已生成 `.o` | objdump/as/ld | 失败原因 |
|---|---|---|---:|---|---|
| tcc | 成功 | **0** | **282**（+102 `.lo`） | **全部生成** | — |
| slimcc | 成功 | **0** | **282**（+102 `.lo`） | **全部生成** | — |
| widcc | 成功 | 2 | 81 | 未生成 | glibc `sys/cdefs.h` 的 `__glibc_const_generic` 使用 `_Generic`；widcc 已移除 `_Generic`，`strchr` 等宏展开失败 |
| pcc | 成功 | 2 | 73 | 未生成 | bundled zlib 的 K&R 旧式定义：`function doesn't match prototype`；另外 pcc 驱动不支持 `--print-prog-name` |
| cproc + QBE | 成功 | 2 | 64 | 未生成 | bundled zlib 的 K&R 旧式定义：`no type in parameter declaration`（C23 语义） |
| xcc | **失败** | — | 0 | 未生成 | xcc 的 mini libc 缺 `ferror`，configure 的 conftest 无法运行：`cannot run C compiled programs` |
| xcc（宿主 as/ld + glibc） | 成功 | 2 | 2 | 未生成 | glibc 头文件下 configure 通过，但 `libiberty/regex.c` 的 `free` 未声明、`liblto_plugin.so` 链接探测失败 |

详细错误：

- **tcc / slimcc（成功）**：完整构建出 `binutils/objdump`、`gas/as-new`、`ld/ld-new`，版本均为 `GNU Binutils 2.44`；`objdump -f /bin/ls` 正常，且用其 as/ld 汇编、链接、运行了 `exit(7)` 的裸汇编程序。tcc 产物：objdump 3,546,394 B、as-new 2,918,178 B、ld-new 3,632,346 B；slimcc 产物：3,553,456 / 2,782,896 / 3,496,904 B。
- **widcc（81 个 `.o`）**：

```text
/usr/include/x86_64-linux-gnu/sys/cdefs.h:837:
# define __glibc_const_generic(PTR, CTYPE, CALL) _Generic (...)
                                     ^ implicit declaration of a function
libiberty/argv.c:226 / vprintf-support.c:60 / simple-object-mach-o.c:1175
```

- **pcc（73 个 `.o`）**：configure 阶段多次出现 `error: unknown option '--print-prog-name'`；构建在 bundled zlib 处终止：

```text
zlib/deflate.c, line 206: function doesn't match prototype
...cannot recover from earlier errors: goodbye!
```

- **cproc（64 个 `.o`）**：bundled zlib 使用 K&R 定义：

```c
uLong ZEXPORT adler32_z(adler, buf, len)
    uLong adler;
    const Bytef *buf;
    z_size_t len;
```

```text
zlib/adler32.c:63:17: error: no type in parameter declaration
```

共 15 次同类错误。

- **xcc**：configure 的 conftest 失败于 `ferror` 未声明（xcc 自带 mini libc 没有该接口），`./conftest` 未生成。

### 4.3 toybox 0.8.15 结果

| 编译器 | defconfig | make | toybox | applet 数 | 失败原因 |
|---|---|---|---|---|---|
| tcc | 成功 | **0**（需规避 `--gc-sections`） | 734,840 B | **239** | 首次链接：`unsupported linker option '--gc-sections'`；改用 `LDOPTIMIZE="-Wl,--as-needed"` 后成功 |
| slimcc | 成功 | **0** | 592,856 B | **239** | — |
| widcc | 成功 | **0** | 2,502,008 B | **239** | — |
| cproc + QBE | 成功 | 2 | 未生成 | 0 | toybox 构建脚本探测 `$CC --version`、`-xc -`、`-E -`；cproc 不支持 `--version`，且 stdin 需要显式 `-x` |
| pcc | 成功 | 2 | 未生成 | 0 | `lib/portability.h:234` 的 `__has_include` 不被 pcc 的 cpp 支持（`junk after expression`） |
| xcc | 成功 | 2 | 未生成 | 0 | 缺少 `<regex.h>`（xcc mini libc 不提供 POSIX regex） |
| xcc（宿主 as/ld + glibc） | 成功 | 2 | 未生成 | 29 | `lib/lib.c:23` 的 GNU `a ? : b` 不被 xcc 支持 |

成功产物的冒烟：`toybox` 列表均为 **239 个 applet**（与 GCC 基线相同），`echo`、`basename`、`wc -l`、`md5sum`、`ls` 均正常。

### 4.4 解读

1. **binutils 是更强的区分器**：它包含大量真实 GNU 代码和 bundled zlib。tcc、slimcc 能完整构建并产出可用的 objdump/as/ld；widcc 卡在新版 glibc 的 `_Generic` 宏；pcc、cproc 卡在 zlib 的 K&R 旧式定义；xcc 默认的 mini libc 路径连 configure 都无法通过（改用宿主 glibc 包装器后见 4.5，仍未能完成构建）。
2. **toybox 更依赖构建脚本/驱动兼容性**：tcc/slimcc/widcc 能构建；cproc 失败于驱动探测（不是 C 语言本身）；pcc 失败于 `__has_include`；xcc 默认 mini libc 缺头文件（宿主 glibc 包装器下能看到更多进展，见 4.5）。
3. **tcc 的 binutils 成功**是本次最值得注意的结果之一：它不仅通过 c-testsuite 和 musl，还能完整构建 binutils 2.44（objdump/as/ld）以及 toybox。
4. **slimcc** 同样完成两个包；结合此前“只差 `_Complex`”的结论，slimcc 是实用性最接近 tcc 的编译器。
5. 所有结果均为 **x86_64 宿主**；未对 binutils/toybox 做 riscv64 交叉尝试。

### 4.5 补充：xcc + 宿主 GNU as/ld + 宿主 glibc

第 4.2/4.3 节的 xcc 失败默认走“自带 mini libc + 自带 as/ld”。为区分“缺 libc 接口”和“xcc 编译器能力”，又做了一组对照：xcc 只负责预处理/编译到汇编，宿主 GNU `as` 汇编，宿主 `gcc`（host ld + glibc）链接。

- **最小验证**：`xcc -S` 生成的 `.s` 可被 GNU as 接受，GNU ld/glibc 链接后正常运行；加 `-I/usr/include -I/usr/include/x86_64-linux-gnu` 后 xcc 可直接使用 glibc 头文件。
- **toybox**：`defconfig` 成功；在补充 `__signed__`/`__BYTE_ORDER__` 等宏、替换 `\e` 转义后，并行构建生成 **29 个 `.o`**；串行复现时首个失败在 `lib/lib.c:23`，即 GNU 三目省略中间操作数 `a ? : b`。未生成 toybox。
- **binutils**：configure **通过**（对比默认 mini libc 下 configure 直接失败），`make` 仍失败：只生成 2 个 `.o`；`libiberty/regex.c` 的 `free` 被 xcc 解析为未声明（`cannot call except function`）；部分链接探测报 `liblto_plugin.so` 找不到。未生成 objdump/as/ld。
- **判定**：有明确进步（configure 通过、toybox 并行构建到 29 个对象），但剩余阻塞已转移到 xcc 语言/驱动能力（GNU 头文件宏、`\e`、`?:`、glibc 声明兼容性、libtool 链接探测），因此仍不能构建这两个包。详细日志在 `xcc/toybox-hostlibc-0.8.15/`、`xcc/binutils-hostlibc-2.44/`、`xcc/binutils-hostlibc2-2.44/`。


---

## 5. 基线评测 III：musl 1.2.5 构建尝试

> **本节要点**：slimcc 只差 `_Complex`；tcc 紧随其后；pcc/widcc 约 50%；xcc/cproc 约 40%，且都缺少多项基础设施。

### 5.1 总表

| 编译器 | 分母（报告口径） | 成功 | 成功率 | `libc.a` | `libc.so` | 首要阻塞 |
|---|---:|---:|---:|---|---|---|
| slimcc | 1352 ALL_OBJS | 1284 | **95.0%** | 否 | 否 | `_Complex`（68） |
| tcc（x86_64） | 2697 编译目标 | 2525 | **93.6%** | 否 | 否 | `_Complex` 68 个源文件 + x86_64 SSE/x87 汇编 17 个 + `sigsetjmp.s` |
| tcc（riscv64） | 1351 编译目标 | 1281 | **94.8%** | 否 | 否 | `_Complex` 68 + `fenv.S`/`tlsdesc.s` |
| pcc | 1345 对象 | 745 | **55.4%** | 否 | 否 | register-asm 变量（534） |
| widcc | 1352 ALL_OBJS | 722 | **53.4%** | 否 | 否 | 内联汇编/寄存器变量（557） |
| xcc（x86_64） | 2697 编译目标 | 1117 | **41.4%** | 否 | 否 | `__builtin_va_list`（825）+ 扩展 asm（512） |
| xcc（riscv64） | 1351 编译目标 | 566 | **41.9%** | 否 | 否 | 同上 + `__attribute__` |
| cproc + QBE | 1345 对象 | 526 | **39.1%** | 否 | 否 | 内联汇编（537）+ `long double`（211）+ `_Complex`（68） |
| xcc（宿主 as/ld + glibc） | — | — | — | — | — | 未测试该模式的 musl 构建 |

> 注：上表中的“成功”指编译出目标文件；除特别说明外，均未生成完整可用的 `libc.a`/`libc.so`。分母差异见 1.3 节。
>
> 作为环境对照：cproc 和 pcc 的报告都先用 GCC 16.2.0 完整构建 musl 1.2.5（`libc.a`/`libc.so` 齐全，静态/动态 hello 可运行）；tcc、slimcc 的后续实验也验证了同一份 tarball 能产出可用 libc。因此下表中的失败不是 tarball 或环境问题。

### 5.2 cproc + QBE：526 / 1345（39.1%）

- configure 成功。
- 默认 `make` 第一步就失败于 `-fPIC`：`cproc: unknown option '-fPIC'`，且 cproc 明确不支持 PIC，因此无法构建 shared `libc.so`。
- 改为只构建静态库：`make -k -j1 lib/libc.a`；1345 个对象中 **526 成功、819 失败**，`libc.a` 未生成。

失败归因：

| 根因 | 数量 | 典型诊断 |
|---|---:|---|
| inline assembly 未支持 | **537** | `arch/x86_64/syscall_arch.h:6:2: error: inline assembly is not yet supported` |
| `long double` 未支持 | **211** | `cproc-qbe: long double is not yet supported` |
| `_Complex` 未支持 | **68** | `include/complex.h:16:8: error: _Complex is not yet supported` |
| `volatile` 存储未支持 | 1 | `src/thread/sem_init.c:10:23: error: volatile store is not yet supported` |
| GNU `packed` attribute 位置 | 1 | `include/sys/epoll.h:53:27: error: GNU attribute 'packed' is not supported here` |
| C23 函数指针语义 | 1 | `src/legacy/ftw.c:7:33: error: base types of pointer assignment must be compatible or void` |
| **合计** | **819** | |

补充：537 个 inline asm 失败中，534 个只是通过 `syscall_arch.h`/`atomic_arch.h` 间接包含；`long double` 的 211 个中有 143 个是因为头文件里未被调用的 `static inline long double` 辅助函数也被 cproc 生成代码。也就是说，**实现 inline asm + 丢弃未引用 static inline + long double** 可以解锁绝大部分对象。

### 5.3 pcc：745 / 1345（55.4%）

- configure 成功；默认 `make` 在第一个对象 `obj/src/aio/aio.o` 就 ICE：

```c
register long r10 __asm__("r10") = a4;   /* syscall_arch.h:37 */
/* pcc: major internal compiler error */
```

- `make -k -j1` 全量统计：1345 个对象中 **745 成功、600 失败**；`libc.a`/`libc.so` 均未生成。

失败归因：

| 根因 | 数量 | 典型诊断 |
|---|---:|---|
| `register ... __asm__("reg")` 寄存器变量 ICE | **534** | `arch/x86_64/syscall_arch.h, line 37: major internal compiler error` |
| 复数类型处理 | **60** | `src/complex/__cexp.c:72: operands of CAST/=` have incompatible types` |
| 复数 `long double` 结构体赋值 | **5** | `assignment of different structures`（`ccoshl.c`、`cexpl.c` 等） |
| 不支持的 xasm 选项 | **1** | `src/math/x86_64/remquol.c:32: unsupported xasm option string 'X'` |
| **合计** | **600** | |

单一特性 register-asm 局部变量就阻塞了 534/600 个失败对象（89%）。

### 5.4 tcc：x86_64 93.6%，riscv64 94.8%

#### x86_64（未修改 musl，失败）

- configure 成功；`make -k -j1 AR=ar RANLIB=ranlib LIBCC=`。
- **2697 个编译目标（`.o` + `.lo`）中 172 失败、2525 成功（93.6%）**；86 个唯一源文件失败；`libc.a`/`libc.so` 未生成。

| 根因 | 唯一源文件数 | 典型位置/错误 |
|---|---:|---|
| `_Complex` | **68** | `include/complex.h:16: _Complex is not yet supported` |
| x86_64 SSE 约束 `x`/`t`/`X` | **16** | `src/math/x86_64/fabs.c:6: unknown constraint 'x'` 等 |
| x87 clobber `st` | **2** | `src/math/x86_64/llrintl.c`/`lrintl.c`：`invalid clobber register 'st'` |
| `@PLT` 汇编后缀 | **1** | `src/signal/x86_64/sigsetjmp.s:14` |
| `expl.s` 汇编语法 | **1** | `src/math/x86_64/expl.s:40` |

#### riscv64（未修改 musl，失败）

- `--disable-shared`：**1351 个目标中 70 失败、1281 成功（94.8%）**；70 个唯一源文件失败。
- 失败构成：68 个 `src/complex/*` + `fenv.S`（`fscsr t1` 伪指令）+ `tlsdesc.s`（`add sp,sp,-16` 伪指令）；`src/math/riscv64/*` 的 `"f"` 约束能正常编译。

#### 最小改动后的结果（实验，明确标注）

| 架构 | 修改 | `libc.a` | 运行验证 |
|---|---|---|---|
| x86_64 | 删除 `src/complex`、删除 `src/math/x86_64`（回退通用 C math）、去掉 `sigsetjmp.s` 的 `@PLT` | 2,653,670 B / 1277 成员 | 用 tcc 链接静态 hello 成功；c-testsuite **220/220** |
| riscv64 | 删除 `src/complex`（以及可选的 `src/math/riscv64`）、`fscsr`→`csrw`、`sll`→`slli`、`add sp,sp,±16`→`addi` | 2,996,466 B / 1278 成员 | qemu 下 hello 成功；c-testsuite **220/220** |

> 这是“去掉复数后的 musl”，不是完整 musl；但它证明 tcc 除 `_Complex` 和少量汇编外已具备构建并使用 musl 的能力。

### 5.5 widcc：722 / 1352（53.4%）

- configure 成功（需 `--target=x86_64-linux-musl`、`AR=ar RANLIB=ranlib`、`CFLAGS=-O0`）。
- `make -k -j1`：**1352 个目标中 722 成功、630 失败**；`libc.a`/`libc.so` 未生成。

| 根因 | 失败对象数 | 典型诊断 |
|---|---:|---|
| GNU 内联汇编 + 显式寄存器变量（syscall 包装） | **528** | `register long r10 __asm__("r10") = a4;` → `expected ','` |
| `_Complex` | **68** | `include/complex.h:16: expected ','` |
| 带操作数的 vDSO/原子内联汇编 | **12** | `arch/x86_64/atomic_arch.h:56` |
| 文件作用域 `__asm__`（CRT/ldso） | **4** | `arch/x86_64/crt_arch.h:1: variable name omitted` |
| x86_64 math 内联汇编 | **16** | `src/math/x86_64/*.c: GNU inline assembly not implemented` |
| `explicit_bzero` 内存屏障 | **1** | `src/string/explicit_bzero.c:7` |
| `offsetof` 不是编译期常量 | **1** | `include/stddef.h:24`（`strptime.c` 的 case 标签） |
| **合计** | **630** | |

### 5.6 slimcc：1284 / 1352（95.0%）

- configure 成功；`make -k -j1`：**1284 成功、68 失败**；失败**全部是 `src/complex/*` 的 `_Complex`**。
- 其余 1284 个对象——包括 syscall/atomic 内联汇编、`register ... __asm__`、文件作用域 asm、x86_64 math 内联汇编、`offsetof` 常量折叠——全部通过。
- 去掉 `src/complex` 后完整构建成功：

```text
lib/libc.a  2,673,522 B
lib/libc.so 1,110,496 B
```

静态/动态 hello、malloc/qsort/sqrt/strptime/pthread/setjmp 综合测试都能运行。**slimcc 只差 `_Complex` 一个特性。**

### 5.7 xcc：41.4%（x86_64）/ 41.9%（riscv64）

- 原始 musl 在 configure 阶段就失败：

```text
checking whether compiler's long double definition matches float.h... no
../musl-src/configure: error: unsupported long double type
```

xcc 的 `sizeof(long double) == 8`，而 musl 要求 x86_64 为 80 位（16 字节存储），riscv64 为 128 位（16 字节）。

- 报告做了“绕过 long double 检查”的实验（明确标注为实验）：

| 架构 | 编译目标 | 成功对象 | 成功率 | `libc.a` |
|---|---:|---:|---:|---|
| x86_64 | 2697 | 1117（558 `.o` + 559 `.lo`） | 41.4% | 未生成 |
| riscv64 | 1351 | 566 | 41.9% | 未生成 |

x86_64 的第一诊断分布（约 1580 个失败目标）：

| 首条诊断位置 | 目标数 | 说明 |
|---|---:|---|
| `obj/include/bits/alltypes.h:326` | **825** | `typedef __builtin_va_list va_list;`：xcc 不认识 GCC 的 `__builtin_va_list` |
| `arch/x86_64/syscall_arch.h:7` | **512** | 带操作数的内联汇编 `__asm__ __volatile__("syscall" : ...)` |
| `include/complex.h` | **136** | `_Complex` |
| `arch/x86_64/atomic_arch.h` | **24** | 原子内联汇编 |
| x86_64 `.s` 文件 | 47 + 22 | `unknown directive` / `line end expected` |
| `#pragma STDC FENV_ACCESS` | 1 | 未处理 |

riscv64 侧错误本质相同，另加 riscv 头文件中的 `__attribute__((aligned(16)))` 不被解析。

### 5.8 musl 缺口矩阵

| 特性 | cproc | pcc | tcc | widcc | slimcc | xcc |
|---|---|---|---|---|---|---|
| GNU 扩展内联汇编（带操作数） | ✗ | 部分（xasm） | ✓ | ✗ | ✓ | ✗ |
| `register T x __asm__("reg")` | ✗ | ✗ | ✓ | ✗ | ✓ | ✗ |
| 文件作用域 `asm` | ✗ | 部分 | ✓ | ✗ | ✓ | ✗ |
| `_Complex` | ✗ | 部分（大量失败） | ✗ | ✗ | ✗ | ✗ |
| `long double` | ✗ | 部分（ABI 问题） | ✓ | ✓ | ✓ | ✗（8 字节） |
| `volatile` 存储 | 部分（仅读取） | ✓ | ✓ | ✓ | ✓ | ✓ |
| PIC / shared libc | ✗（无 `-fPIC`） | 未验证 | 部分（native `libc.so` 失败） | 未验证 | ✓ | 未验证 |
| GCC `__builtin_va_list` | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ |
| GNU `__attribute__` | 部分（位置） | 部分 | ✓ | ✓ | ✓ | ✗ |
| C23 `()` = 无参数 | 是（刻意） | 否 | 否 | 否 | 否 | 否 |
| `#pragma push_macro/pop_macro` | ✓ | ✗ | ✓ | ✗ | ✗ | ✗ |

说明：

- tcc 的 `long double` 在 musl configure 检查中通过，x86_64 musl 构建失败主要不是 `long double` 而是 `_Complex`/SSE 汇编；riscv64 亦然。
- pcc 的 `long double` 基础类型可用，但 `00204` 的返回/HFA ABI 仍错误。
- cproc 的 `volatile` 仅实现读取，`volatile store` 未实现。
- “部分”表示只覆盖部分语法/位置，不能通过 musl 的全部相关代码。

### 5.9 关于“用 X 构建 musl 成功”的界定

本文只把以下情况称为“构建成功”：

1. 生成完整的 `libc.a`（或 `libc.so`）；
2. 用该 libc 能链接一个真实程序并运行；
3. 尽可能用该 libc 跑通测试。

按此标准：

| 编译器 | 未修改 musl | 最小源码修改后 |
|---|---|---|
| slimcc | 失败（仅 `_Complex`） | **成功**（删除 `src/complex`，静态/动态/多线程均验证） |
| tcc | 失败 | **成功**（删除复数/架构 math + 少量汇编补丁，x86_64/riscv64 均验证） |
| 其他 | 失败 | — |

---

## 6. 相互构建：四个编译器两两互建

> **本节要点**：12 个交叉组合中，tcc、slimcc、cproc 之间基本可以互建；xcc 作为源编译器时受其 mini libc 和前端 bug 限制，只能构建 tcc/cproc；cproc 因缺少 `long double` 无法构建 tcc/xcc；QBE 因 xcc 不支持函数类型形参而无法被 xcc 构建。
>
> 完整命令、日志和逐项产物见 [`pairwise/pairwise-build-report.md`](pairwise/pairwise-build-report.md)。

### 6.1 目标与口径

- 范围：仅 x86_64；宿主与目标均为 x86_64 Linux/glibc。
- 四个编译器：**tcc**、**slimcc**、**xcc**、**cproc + QBE**。
- 12 个交叉组合：每个目标编译器用另外三个编译器分别构建；自身构建不计数，仅作对照。
- 对 `cproc-qbe/{cproc,qbe}` 按“整对”处理：目标侧要求 `cproc` 与 `qbe` 都能由同一个源编译器产出。
- 对 xcc 按题目要求先尝试“自带 `cpp/cc1/as/ld` + mini libc”，失败后再回退到“系统 as/ld + glibc + 系统头文件”。
- 验证层级：
  1. 构建产物存在、`--version` 正常；
  2. 产物能编译并运行 hello 与 stress 程序；
  3. 尽可能做 stage2 自举（tcc/slimcc/cproc）或 gen2/gen3（xcc）；
  4. 用统一的 c-testsuite runner 与原生编译器对比。

源编译器（原生、由 gcc 构建）：

| 编译器 | 原生路径 | 版本/commit |
|---|---|---|
| tcc | `tcc/install-native/bin/tcc` | 0.9.28rc，`2be0218b` |
| slimcc | `widcc-slimcc/slimcc/slimcc` | `2388c39` |
| xcc | `xcc/build-native/xcc` | 0.1.13，`83c51319` |
| cproc + QBE | `cproc-qbe/cproc/cproc` + `cproc-qbe/qbe/qbe` | cproc `d1c53dd` / QBE `180d2eb` |

### 6.2 12 个组合总表

图例：✅ 直接成功；⚠️ 回退到系统工具/库后成功；⚠️* 部分成功；❌ 失败；— 自身构建（不计数）。

| 目标 ＼ 来源 | tcc | slimcc | xcc | cproc |
|---|---|---|---|---|
| **tcc** | —（自举对照） | ✅ | ⚠️→✅ | ❌ |
| **slimcc** | ✅ | — | ❌ | ✅（bootstrap 选项） |
| **xcc** | ✅ | ✅ | — | ❌ |
| **cproc + QBE** | ✅ | ✅ | ⚠️*（cproc 成功 / QBE 失败） | — |

统计（按目标/来源计）：

- 直接成功：**7** 组（tcc←slimcc、slimcc←tcc、slimcc←cproc、xcc←tcc、xcc←slimcc、cproc+QBE←tcc、cproc+QBE←slimcc）
- 回退后成功：**1** 组（tcc←xcc）
- 部分成功：**1** 组（cproc+QBE←xcc：cproc 成功，QBE 失败）
- 失败：**3** 组（tcc←cproc、slimcc←xcc、xcc←cproc）

即 **9/12 成功或部分成功，3/12 失败**。

### 6.3 逐组合结果

#### 6.3.1 tcc ← slimcc：✅

- out-of-tree `configure --cc=<slimcc>` + `make` + `make install` 一次通过。
- 产物 `install/bin/tcc` 编译/运行 hello 与 stress 正确。
- stage2：用该 tcc 再构建 tcc 成功，产出的 tcc 也能编译 hello。
- c-testsuite：**220/220**，与原生 tcc 相同。

#### 6.3.2 tcc ← xcc：⚠️ 自带工具/库失败 → 系统工具/库成功

1. 原生 xcc（自带工具链 + mini libc）失败于 `Cannot open file: <sys/time.h>`。
2. 回退方案：用 gcc 构建一个“系统 as/ld”版 xcc（`-DUSE_SYS_AS -DUSE_SYS_LD`，记为 `xcc-sys`），并给 xcc 补：
   - 系统头文件路径：`-I/usr/include -I/usr/include/x86_64-linux-gnu`；
   - GCC 预定义类型宏：`__SIZE_TYPE__`、`__PTRDIFF_TYPE__`、`__WCHAR_TYPE__`、`__WINT_TYPE__`、`__INTMAX_TYPE__`、`__UINTMAX_TYPE__`；
   - 链接 `-Wl,-no-pie`（xcc 生成非 PIC 目标文件，glibc 默认 PIE 会失败）。
3. 结果：构建成功；hello/stress 正确；stage2 成功；c-testsuite **220/220**。
4. 产物为动态链接 glibc、未 strip，大小 600,496 B（原生 381,600 B）。

#### 6.3.3 tcc ← cproc：❌

```
cproc-qbe: long double is not yet supported
```

触发文件 `tccgen.c`。tcc 源码大量使用 `long double`，cproc/QBE 对 16 字节 `long double` 直接 fatal；没有编译选项可绕过。

#### 6.3.4 slimcc ← tcc：✅

- 构建成功；hello/stress 正确；stage2 成功。
- c-testsuite：**219/220**，唯一失败 `00206`，与原生 slimcc 完全一致。

#### 6.3.5 slimcc ← xcc：❌

1. 原生 xcc 失败于 `Cannot open file: <glob.h>`。
2. 回退到 `xcc-sys` + 系统头文件后，cc1 在编译 `parse.c`、`type.c` 时断言崩溃：

```
cc1: src/cc/frontend/initializer.c:200: reserve_init_for_multi:
     Assertion `sinfo != NULL' failed.
```

3. 结论：xcc 前端处理 slimcc 源码中的某个聚合初始化时触发内部断言，换 libc/工具链不解决。

#### 6.3.6 slimcc ← cproc：✅（需要两个明确的构建选项）

1. slimcc README 指定 cproc 需要：
   ```
   -DBOOTSTRAP_NO_LDOUBLE -U__has_builtin
   ```
2. cproc 驱动用 `cpp -undef` 但不提供 glibc 需要的 GCC 类型宏；需要包装脚本补：
   ```
   -D__SIZE_TYPE__=unsigned long  -D__PTRDIFF_TYPE__=long
   -D__WCHAR_TYPE__=int  -D__WINT_TYPE__=unsigned int
   -D__INTMAX_TYPE__=long int  -D__UINTMAX_TYPE__=long unsigned int
   ```
   否则 glibc `glob.h` 报 `declaration has no type specifier`。
3. 结果：构建成功；hello/stress 正确；stage2 成功。
4. c-testsuite：**218/220**。比原生 slimcc 多失败 `00204`（HFA/`long double` 结构体变参）；这是 `BOOTSTRAP_NO_LDOUBLE` 把内部 `long_double_t` 变成 `double` 导致的已知代价，不是 cproc 把 slimcc 编译坏了。

#### 6.3.7 xcc ← tcc：✅

- `make exes` 一次成功，生成 `xcc/cpp/cc1/as/ld`。
- 产出的 `./xcc` 用自带 ld + mini libc 生成静态 hello，运行正确。
- 自举：`make gen2`、`make gen3` 均成功；gen2/gen3 五个程序的 `.text/.rodata/.data` 逐字节相同，原始二进制仅符号表/字符串表顺序不同（cc1 8 B、cpp/ld 30 B、xcc 60 B、as 完全一致）。
- c-testsuite：**214/220**，失败集合与原生 xcc 完全相同：`00162`、`00178`、`00202`、`00206`、`00209`、`00216`。

#### 6.3.8 xcc ← slimcc：✅

- 与 6.3.7 相同：一次成功，gen2/gen3 成功。
- c-testsuite：**214/220**，失败集合与原生 xcc 相同。

#### 6.3.9 xcc ← cproc：❌

- 失败点：`cproc-qbe: long double is not yet supported`，触发文件 `src/cc/frontend/initializer.c`、`expr.c`。
- xcc 源码使用 `long double`，cproc 无法编译。

#### 6.3.10 cproc + QBE ← tcc：✅

- QBE 构建成功，合法 `.ssa` 输入可正常输出汇编。
- cproc 的 `cproc` 与 `cproc-qbe` 均构建成功，配置指向同一 tcc 构建出的 QBE。
- hello/stress 正确；stage2 成功；stage2 产物也能编译 hello。
- c-testsuite：**212/220**，失败集合与原生 cproc 完全相同（`00141`、`00144`、`00204`、`00209`、`00210`、`00213`、`00214`、`00216`）。

#### 6.3.11 cproc + QBE ← slimcc：✅

- QBE、cproc、cproc-qbe 全部构建成功；hello/stress 正确；stage2 成功。
- c-testsuite：**212/220**，失败集合与原生 cproc 相同。

#### 6.3.12 cproc + QBE ← xcc：⚠️ 部分成功

1. 原生 xcc（自带工具/库）编译 cproc 驱动失败：
   - `Cannot open file: <spawn.h>`；
   - `freopen`/`ferror` 未声明；
   - `uint_least32_t` 未定义（mini libc 的 `stdint.h` 不全）。
2. 回退到 `xcc-sys` 后：
   - **cproc 驱动与 cproc-qbe 主体构建成功**；hello/stress 正确；stage2 成功；c-testsuite **212/220**，与原生 cproc 完全一致。
   - **QBE 仍然失败**，且不是 libc 问题：
     ```
     all.h(539): `)' expected
     void parse(FILE *, char *, void (char *), void (Dat *), void (Fn *));
     ```
     xcc 不支持**不带参数名的函数类型形参**。此外原生 xcc 还缺 `<getopt.h>`、`inttypes.h` 的 `PRIi64` 宏；即使换系统头文件，函数类型形参这一条仍然卡住。
3. 结论：xcc 可以构建 cproc 编译器本体，但无法构建 QBE；“cproc + QBE”整对只完成一半。

### 6.4 保真度验证

#### 6.4.1 stress 程序

所有成功产物都能编译一个包含结构体/联合体/位域/变参/函数指针/长整型/浮点/字符串的 stress 程序，输出与 gcc 基线逐字节相同：

| 产物 | stress |
|---|---|
| tcc ← slimcc | ✅ |
| tcc ← xcc（回退） | ✅ |
| slimcc ← tcc | ✅ |
| slimcc ← cproc | ✅ |
| xcc ← tcc | ✅ |
| xcc ← slimcc | ✅ |
| cproc ← tcc | ✅ |
| cproc ← slimcc | ✅ |
| cproc ← xcc（回退） | ✅ |

#### 6.4.2 stage2 / 自举

| 产物 | 自举结果 |
|---|---|
| tcc ← slimcc | 再构建 tcc 成功 |
| tcc ← xcc（回退） | 再构建 tcc 成功 |
| slimcc ← tcc | `slimcc-stage2` 成功 |
| slimcc ← cproc | `slimcc-stage2` 成功 |
| xcc ← tcc | `gen2`、`gen3` 成功，代码段逐字节一致 |
| xcc ← slimcc | `gen2`、`gen3` 成功，代码段逐字节一致 |
| cproc ← tcc | `make stage2` 成功 |
| cproc ← slimcc | `make stage2` 成功 |
| cproc ← xcc（回退） | `make stage2` 成功 |

#### 6.4.3 与原生编译器的 c-testsuite 对照

统一 runner、统一选项；xcc 不加 `-lm`（其 libc 已含数学函数），其余加 `-std=c11 -lm`。

| 编译器 | 构建来源 | 通过/总数 | 与原生相比 |
|---|---|---:|---|
| tcc 原生 | gcc | 220/220 | — |
| tcc | slimcc | 220/220 | 一致 |
| tcc | xcc（回退） | 220/220 | 一致 |
| slimcc 原生 | gcc | 219/220（`00206`） | — |
| slimcc | tcc | 219/220（`00206`） | 一致 |
| slimcc | cproc（bootstrap） | 218/220（`00204`,`00206`） | 多 `00204`，因 `BOOTSTRAP_NO_LDOUBLE` |
| xcc 原生 | gcc | 214/220 | — |
| xcc | tcc | 214/220 | 失败集合完全一致 |
| xcc | slimcc | 214/220 | 失败集合完全一致 |
| cproc 原生 | gcc | 212/220 | — |
| cproc | tcc | 212/220 | 失败集合完全一致 |
| cproc | slimcc | 212/220 | 失败集合完全一致 |
| cproc | xcc（回退） | 212/220 | 失败集合完全一致 |

> 注：本节 runner 统一加 `-lm`，因此 cproc 比 §0.1/§3 的基线口径多通过 `00174`（212 vs 211）；xcc 不加 `-lm`。

### 6.5 关键兼容性问题

1. **tcc / slimcc 的代码互兼容性最好**：两者互建成功，且都能构建 xcc 和 cproc。
2. **cproc 的 `long double` 缺口**：直接阻断 tcc ← cproc、xcc ← cproc。
3. **cproc 的外部 cpp 配置缺口**：`cpp -undef` + 不提供 GCC 类型宏，使 glibc 头文件无法预处理；可用包装脚本补宏，也可用 musl 头文件绕过。
4. **xcc 的 mini libc 不完整**：缺 `sys/time.h`、`glob.h`、`spawn.h`、`getopt.h`、`locale.h`、`uint_least32_t`、`PRIi64` 等；作为源编译器时通常需要回退到系统 as/ld + glibc。
5. **xcc 的前端 bug**：编译 slimcc 时 cc1 在 `initializer.c:200` 断言；编译 QBE 时不支持无名函数类型形参。
6. **xcc 的链接约束**：生成非 PIC 目标文件，用 glibc 链接时必须加 `-Wl,-no-pie`。

### 6.6 小结

| 维度 | 结论 |
|---|---|
| 作为目标被构建 | tcc、slimcc、xcc、cproc 都能被至少两个别的编译器构建；xcc 作为目标最容易被构建（tcc、slimcc 均成功） |
| 作为源编译器 | tcc、slimcc 最可靠；cproc 受 `long double` 限制；xcc 受 mini libc 和前端 bug 限制 |
| 构建保真度 | 除 slimcc ← cproc 的 `BOOTSTRAP_NO_LDOUBLE` 语义差异外，成功产物的 c-testsuite 结果与原生完全一致 |
| 最大障碍 | cproc 缺 `long double`（3 组失败中的 2 组）；xcc 前端 bug（1 组失败 + 1 组部分成功） |

## 7. 应用构建：EDG C++ 前端 5.1

> **本节要点**：tcc 和 slimcc 能完整构建 EDG 5.1（前端 + C++ 运行库 + C/C++17/异常 smoke test）；xcc 因前端类型补全 bug 段错误；cproc 因不支持 `long double` 失败。
>
> 完整日志、产物和最小复现见 [`edg5.1-try/edg5.1-build-report.md`](edg5.1-try/edg5.1-build-report.md)。

### 7.1 输入与参考流程

- 输入：`edgcpp-compiler-5.1.tar.gz`（263 个文件；前端 63 个 C 源，C++ 运行库 51 个 `.c`）。
- 参考脚本：`edgcpp-try/refhost-edg5.1.sh`。
- EDG 5.1 的前端是**纯 C**（`-std=gnu89` 风格，依赖 `-fcommon` 的 tentative definition 合并）；C++ 运行库先由 edgcpfe 翻译成 C，再由 C 编译器编译。
- 流程：
  1. 编译并运行 `util/mk_errinfo.c`，生成 `src/err_codes.h`、`src/err_data.h`；
  2. 用 `-std=gnu89 -fcommon` 编译 63 个前端源文件，链接 `edgcpfe`；
  3. `--version` 检查；
  4. 翻译一个 C 程序，编译生成的 C，运行；
  5. 用 edgcpfe 把 51 个 `lib_src/*.c`（C++）翻译成 C，再由同一个 C 编译器编译，`ar` 成 `libC.a`；
  6. 翻译 C++17 程序与异常程序，链接 `libC.a`，运行。
- 方法适配：EDG 在翻译 C++ 时如果使用 glibc 头文件，会撞上 `bits/floatn.h` 的 `__float128` / `__attribute__((__mode__))`（gcc 基线也会在此失败），因此 EDG 的 `--sys_include` 指向 musl rootfs 的 `/usr/include`；生成 C 的编译仍使用各编译器默认的 glibc。

### 7.2 总表

| 编译器 | 前端 edgcpfe（63 个 C 源） | C++ 运行库 libC.a（51 个 C++→C） | C / C++17 / 异常 smoke test | 结论 |
|---|---|---|---|---|
| **tcc** | ✅ 63/63 | ✅ 51/51 | ✅ 全部通过 | **完整构建成功** |
| **slimcc** | ✅ 63/63 | ✅ 51/51 | ✅ 全部通过 | **完整构建成功** |
| **xcc** | ❌ cc1 段错误 | — | — | 失败：前端类型补全 bug |
| **cproc** | ❌ 不支持 `long double` | — | — | 失败：语言特性缺口 |

### 7.3 tcc：完整成功

- 63 个前端源文件全部编译通过，`build/edgcpfe` 7,306,668 B；`--version` 输出 `version 5.1`。
- 51 个运行库源文件全部翻译、编译成功；`lib/libC.a` 156,168 B，51 个对象。
- C smoke test、C++17 smoke test、C++ 异常 smoke test 全部通过。
- 编译日志无 error/warning（使用 `-w`）。

### 7.4 slimcc：完整成功

- 63 个前端源文件全部编译通过，`build/edgcpfe` 6,700,256 B；版本检查通过。
- 51 个运行库源文件全部翻译、编译成功；`lib/libC.a` 123,826 B，51 个对象。
- C/C++17/异常 smoke test 全部通过。
- 唯一噪声：编译 glibc 头文件时出现 `_BSD_SOURCE and _SVID_SOURCE are deprecated` 的 `#warning`（EDG 的 `defines_linux.h` 定义了 `_BSD_SOURCE`），不影响构建。

### 7.5 xcc：失败（前端 cc1 段错误）

#### 7.5.1 第一次尝试：xcc 自带工具/库

```
Cannot open file: <locale.h>
FATAL: mk_errinfo compile
```

xcc 的 mini libc 头文件集没有 `locale.h`，连 `util/mk_errinfo.c` 都编译不过。EDG 前端使用的 `sys/time.h`、`sys/resource.h` 等也不在 xcc 的 mini libc 中。

#### 7.5.2 第二次尝试：回退到系统工具/库

用系统 as/ld/glibc 的 xcc 变体（`-DUSE_SYS_AS -DUSE_SYS_LD`），并加系统头文件路径、GCC 类型宏、`-D_DEFAULT_SOURCE` 避开 glibc 的 `#warning` 后：

- `mk_errinfo` 编译、运行成功；
- 前端编译到 `src/class_decl.c` 时 **cc1 段错误**。

逐文件编译确认：`attribute.c`、`cfe.c`、`c_gen_be.c` 正常，`class_decl.c` 崩溃。

#### 7.5.3 崩溃定位

用 gdb 调试 xcc 的 `cc1`（先 `xcc -E` 预处理，再 `cc1 -O2 -fcommon -` 读入）：

```
Program received signal SIGSEGV
0x... in gen_assign_sub (lhs=..., rhs=...)
    at src/cc/backend/codegen_expr.c:859
859     if (lhs->type->struct_.info->size > 0) {
(gdb) p lhs->type->kind
$1 = TY_STRUCT
(gdb) p lhs->type->struct_.info
$2 = (StructInfo *) 0x0
(gdb) p lhs->token->line->lineno
$3 = 29032
(gdb) x/s lhs->token->line->filename
$4 = "src/class_decl.c"
```

对应源码 `src/class_decl.c:29032`：

```c
if (decl_pos_block_ptr != NULL) {
  *decl_pos_block_ptr = decl_info.decl_pos_block;
}
```

`decl_pos_block_ptr` 的类型是 `a_decl_pos_block_ptr`，而 `src/il.h` 中的声明顺序是：

```c
typedef struct a_decl_pos_block *a_decl_pos_block_ptr;
typedef struct a_decl_pos_block {
  ...
} a_decl_pos_block;
```

即：**先 `typedef` 了一个“指向不完整 struct 的指针”，随后才用另一个 typedef 定义这个 struct**。xcc 的前端没有把后一个完整定义关联回前一个指针 typedef，导致 `a_decl_pos_block_ptr` 指向的类型始终是“不完整 struct”，`StructInfo` 为 NULL；后端做结构体赋值时直接解引用空指针。

#### 7.5.4 最小复现

下面这段合法 C（gcc 可编译并运行）会让 xcc 段错误：

```c
typedef struct S *S_ptr;
typedef struct S { int x; } S;
int main(void) {
  S a, b;
  S_ptr p = &a;
  *p = b;           /* struct assignment through pointer typedef */
  return 0;
}
```

| 变体 | gcc | xcc |
|---|---|---|
| 上述完整用例 | ok | **SIGSEGV (139)** |
| 去掉 `*p = b;`，只 `p->x = 1` | ok | ok |
| 直接 `a = b;`（不经过指针 typedef） | ok | ok |
| `struct S; typedef struct S *S_ptr; struct S { int x; };` | ok | **SIGSEGV** |
| 把 `typedef struct S *S_ptr;` 放到 struct 定义之后 | ok | ok |

触发条件：**指向不完整 struct 的指针 typedef 先出现，struct 的完整定义后出现，且通过该指针做结构体赋值**。

#### 7.5.5 这不是 EDG 的个例

`il.h` 只是第一个命中的位置；EDG 5.1 多个头文件都使用同样的写法，例如 `src/error.h`：

```c
typedef struct a_diag_list *a_diag_list_ptr;
typedef struct a_diag_list {
  ...
} a_diag_list;
```

在临时副本中把 `il.h` 的 typedef 顺序调整正确，并给 xcc 补上它缺失的 `LDBL_*` 宏（xcc 自带的 `float.h` 没有 `LDBL_DIG`/`LDBL_MANT_DIG` 等），xcc 继续编译到第 35 个文件 `src/interpret.c` 时再次段错误，崩溃点仍是 `gen_assign_sub`，源码行是：

```
src/interpret.c:15413:  *diag_list = ips.diag_list;
```

而 `diag_list` 的类型 `a_diag_list_ptr` 正来自 `error.h` 的同款写法。也就是说，**xcc 的这个前端缺陷在 EDG 中会反复出现**，不是改一个头文件就能绕过的问题。

### 7.6 cproc：失败（`long double` 不支持）

#### 7.6.1 第一次尝试：cproc 默认配置 + glibc

cproc 的驱动不接受 `-w`、`-fcommon`，使用 `-O2 -std=gnu89`。第一条源文件就失败：

```
../../src/lexical.h:1872:13: error: undeclared identifier: __SCHAR_MAX__
cproc: compile: process 86 exited with status 1
```

原因：cproc 调用外部 `cpp` 时使用 `-undef`，而它的 `config.h` 只提供很少的 GCC 预定义宏，没有 `__SCHAR_MAX__`、`__SIZE_TYPE__`、`__restrict` 等；glibc 头文件需要这些宏。

#### 7.6.2 第二次尝试：musl 头文件 + gcc 预处理

cproc 支持预处理的 `.i` 输入（`CPPOUT`）。用 gcc 作为外部预处理器，采用 musl 头文件并去掉 GCC 扩展属性：

```sh
gcc -E -nostdinc -isystem <musl>/usr/include -isystem <gcc-include> \
    -std=gnu89 -D_DEFAULT_SOURCE -U__GNUC__ '-D__attribute__(x)=' \
    -D__extension__= -D__inline=inline -D__inline__=inline -I src src/X.c -o X.i
cproc -c X.i -o X.o
```

这样头文件层不再报错，cproc 成功编译了前 22 个文件（`attribute.c` 到 `floating.c`）；到第 23 个文件 `src/float_pt.c` 时失败：

```
cproc-qbe: long double is not yet supported
cproc: compile: process 210 exited with status 1
FATAL: cproc compile src/float_pt.c
```

#### 7.6.3 根因

- `src/float_pt.c` 一个文件就有 **86 处** `long double`；`c_gen_be.c`、`decl_spec.c`、`expr.c`、`fixed_pt.c`、`folding.c`、`il_to_str.c`、`lexical.c`、`literals.c`、`lower_c99.c`、`lower_name.c`、`overload.c`、`symbol_tbl.c`、`basics.h`、`floating.h`、`float_pt.h` 等也都使用。
- Linux x86_64 的 EDG 配置里 `USE_LONG_DOUBLE_FOR_HOST_FP_VALUE=1`，宿主浮点值用 80 位 `long double` 表示；目标 `TARG_SIZEOF_LONG_DOUBLE=16`。
- cproc/QBE 的 `qbe.c:206` 对 16 字节 `long double` 直接 `fatal("long double is not yet supported")`。
- 尝试 `-DUSE_LONG_DOUBLE_FOR_HOST_FP_VALUE=0` 会触发 EDG 的配置一致性检查：
  ```
  #error -- TARG_SIZEOF_DOUBLE must equal TARG_SIZEOF_LONG_DOUBLE when
            LONG_DOUBLE_AS_DOUBLE_IN_GENERATED_C is TRUE
  ```
  必须把目标 `long double` 也改成 8 字节（类似 Windows 配置），这会改变目标 ABI，不是“用 cproc 构建原配置的 EDG”。

### 7.7 失败原因对比

| 编译器 | 失败阶段 | 直接错误 | 根因类型 |
|---|---|---|---|
| **xcc** | 前端编译 `src/class_decl.c` | cc1 SIGSEGV，`gen_assign_sub` 解引用 NULL `StructInfo` | xcc 前端 bug：指向不完整 struct 的指针 typedef 未被后续 struct 定义补全 |
| **cproc** | 前端编译 `src/float_pt.c` | `cproc-qbe: long double is not yet supported` | cproc/QBE 语言特性缺口：16 字节 `long double` 未实现 |
| cproc（更早一层） | 前端编译 `attribute.c` | `__SCHAR_MAX__` 未定义 | cproc 外部 cpp 用 `-undef` 但未提供 glibc 需要的 GCC 预定义宏 |
| xcc（更早一层） | `mk_errinfo` | `Cannot open file: <locale.h>` | xcc mini libc 头文件集不完整 |
| xcc（回退后更早一层） | glibc `features.h` | `#warning` 被 xcc 当成 unknown directive | xcc 预处理器不认 glibc 的 `#warning`；加 `-D_DEFAULT_SOURCE` 可绕过 |

### 7.8 小结

- **tcc、slimcc** 能处理 EDG 的 K&R 风格定义、`-fcommon` tentative definitions、GNU 扩展头文件用法，以及 EDG 生成的 C；两者都完整构建了前端、运行库和 smoke test。
- **xcc** 的失败是前端/后端的实现 bug（不完整 struct 指针 typedef），与 EDG 代码可移植性无关。
- **cproc** 的失败是 `long double` 语言特性缺口；外部 cpp 的预定义宏配置是更早一层、可绕过的问题，但绕过之后仍然卡在 `float_pt.c`。

## 8. 综合结论与建议

> **本节要点**：tcc 最接近“能测试、能自举、能构建真实项目”；slimcc 是最容易补全的；xcc/pcc/cproc 各有结构性缺口。

### 8.1 综合排序

1. **tcc**：c-testsuite 唯一满分；riscv64 也能满分；musl 只差复数和少量汇编。唯一显著限制是 riscv64 链接器不能消费 GCC 目标文件。
2. **slimcc**：219/220；musl 的唯一缺口是 `_Complex`，去掉后完整可用。适合作为“补一个特性就能完整构建 musl”的候选。
3. **widcc**：217/220；但 musl 仅 53.4%，缺内联汇编、寄存器变量、文件作用域 asm、`_Generic` 等，离 musl 较远。
4. **xcc**：214/220（riscv 213/220）；工程完整度高，但缺 GCC `va_list`、扩展 asm、`_Complex`、`__attribute__`、16 字节 `long double`，musl 约 41%。
5. **cproc + QBE**：211/220；c-testsuite 失败均为功能缺口而非 miscompile；riscv 交叉 193/220，且额外失败已定位为 QBE rv64 的 extern+offset 限制。musl 39.1%，缺 inline asm、long double、复数等。
6. **pcc**：207/220，宿主可用；riscv 后端未完成；musl 55.4%，register-asm 变量是最大单点。

### 8.2 各编译器最值得优先修复的点

| 编译器 | 优先级最高的修复 | 预计收益 |
|---|---|---|
| tcc | `_Complex`；riscv64 链接器的 `R_RISCV_HI20/LO12_I/LO12_S` 重定位 | 完整 musl；可直接链接 GCC 目标文件 |
| slimcc | `_Complex` | 直接获得完整 musl 构建能力 |
| widcc | 带操作数的内联汇编 + 寄存器变量 + 文件作用域 asm | 一次解锁 544/630 个 musl 失败对象 |
| xcc | **不完整 struct 指针 typedef 的类型补全**；GCC 兼容 `__builtin_va_list` + 扩展内联汇编 + `_Complex`；mini libc 的 `locale.h`/`glob.h`/`spawn.h` 等 | 解锁 slimcc/EDG 5.1；从 41% 提升到可讨论构建 musl 的范围 |
| cproc | **`long double`**；inline asm + `_Complex`；外部 cpp 的 GCC 预定义宏；QBE rv64 的 extern+offset | 解锁 EDG 5.1 与 tcc/xcc 互建；musl 对象提升到 95% 以上 |
| pcc | register-asm 局部变量；`_Complex`/long double 结构体赋值 | 解锁 534/600 个 musl 失败对象 |

> xcc 的“指针 typedef 先于 struct 定义”是本次新发现的高性价比修复点：修复后不仅能构建 slimcc（目前 cc1 断言），还可能让 xcc 具备构建 EDG 5.1 的基础（EDG 的 `il.h`、`error.h` 等多处使用该写法）。

### 8.3 需要强调的“非缺陷”失败

- cproc `00141`：测试本身读取未初始化变量（UB）；cproc/QBE 拒绝不是标准违反。
- cproc `00144`：丢弃 `const` 是约束违反；cproc 报 error、GCC 只警告，属于诊断严格度差异。
- cproc `00174` / pcc `00174`：驱动默认不链接 `-lm`；加 `-lm` 即通过。
- cproc `00209`：cproc 刻意采用 C23 `()` 语义，与 c89 测试冲突。
- cproc `00216` / xcc `00216` / pcc `00216` / widcc `00216`：都涉及 GNU 扩展或空 struct/复合字面量，不属于 ISO C 必需特性的一部分（但 c-testsuite 把它们标为 portable）。

---

### 8.4 相互构建与 EDG 5.1 的结论

把“能否构建别人”和“能否构建真实应用”放在一起看，四个编译器的兼容性画像如下：

| 编译器 | 作为目标被构建 | 作为源编译器构建别人 | 构建 EDG 5.1 | 主要限制 |
|---|---|---|---|---|
| **tcc** | 容易被 slimcc/xcc 构建 | 最可靠；能构建 slimcc/xcc/cproc | ✅ 完整成功 | `long double` 可用，未发现新的结构性缺口 |
| **slimcc** | 容易被 tcc/cproc 构建 | 能构建 tcc/xcc/cproc | ✅ 完整成功 | 需要 cproc 的 `BOOTSTRAP_NO_LDOUBLE`；`_Complex` 仍是 musl 缺口 |
| **xcc** | 容易被 tcc/slimcc 构建 | 只能构建 tcc/cproc（且需回退系统库） | ❌ | mini libc 头文件不完整；前端“不完整 struct 指针 typedef”bug；不支持 `long double` |
| **cproc + QBE** | 容易被 tcc/slimcc 构建 | 能构建 slimcc（及自身）；不能构建 tcc/xcc | ❌ | 不支持 `long double`、inline asm、`_Complex`；外部 cpp 预定义宏不全 |

几个值得单独强调的事实：

1. **tcc 和 slimcc 是“双向兼容性”最好的两个**：它们既能被对方构建，也能构建 xcc 和 cproc，还能完整构建 EDG 5.1。tcc 在作为源编译器的 3 个组合中全部成功（构建 slimcc/xcc/cproc+QBE）。
2. **cproc 的 `long double` 缺口影响面最大**：它同时阻断 tcc ← cproc、xcc ← cproc 和 EDG 5.1 三处；在 musl 构建中也是 211 个对象失败的原因。
3. **xcc 的“自带生态”是双刃剑**：作为目标时很容易被构建（源码兼容性好），作为源编译器时却被 mini libc 的头文件缺口和前端 bug 限制；它的 c-testsuite 214/220 与原生一致，说明构建出的 xcc 本身是可靠的。
4. **EDG 5.1 是一个比 c-testsuite 更“重”的 C 代码兼容性测试**：它包含 63 个 gnu89/K&R 风格源文件、`-fcommon` tentative definitions、大量宿主 `long double`，以及 51 个由 EDG 自己生成的 C 文件。tcc/slimcc 全部通过，xcc/cproc 分别被前端 bug 和 `long double` 挡住。

### 8.5 总体评价

- 如果目标是“一个能通过全部 c-testsuite、并能自举 musl 的 C 编译器”，**tcc** 是当前最接近的；**slimcc** 只差一个 `_Complex`，工程量最小。
- 如果目标是“多架构、可交叉”，**cproc + QBE** 的架构最清晰（前端 + 多后端），但 QBE rv64 与 cproc HEAD 的 `extern` 接口问题必须修复；**xcc** 的多架构工程也完整，但语言特性缺口比 cproc 更多。
- **pcc** 是历史最久、后端最多的项目，但本仓库的 riscv 后端尚未完成；其宿主 amd64 结果仍然稳健（207/220），musl 55.4% 说明 register-asm 是下一步最值得补的能力。
- **widcc** 是“删减版 slimcc”，通过 c-testsuite 的比例很高，但 musl 失败集中在内联汇编和寄存器变量这类基础设施上，修复成本明显高于 slimcc 补 `_Complex`。
- 所有六个编译器在**同一份 220 项测试、同一份 musl 1.2.5、同一个 GCC 16.2.0 环境**下对比，横向数据具有较好的一致性；唯一需要留意的是各报告对 musl 对象数量的统计口径不同（见 1.3 节）。

## 9. 产物、日志与复现

| 项目 | 报告 | 主要结果/日志 |
|---|---|---|
| cproc + QBE | [cproc-report-1.md](cproc-qbe/cproc-report-1.md)、[cproc-report-2.md](cproc-qbe/cproc-report-2.md) | `cproc-qbe/.ctest-work/results.tsv`、`riscv-build/ctest/results.tsv`、`musl-build/build-cproc/` |
| pcc | [pcc-testsuite.md](pcc/pcc-testsuite.md) | `pcc/ctest-work/host-final/results.tsv`、`pcc/ctest-work/se-root/report.tap`、`pcc/musl-work/` |
| tcc | [tcc-testsuite.md](tcc/tcc-testsuite.md) | `tcc/ctest-work/*.tap`、`tcc/musl-build-*/`、`tcc/musl-build-*/analysis.txt` |
| widcc | [widcc-testsuite.md](widcc-slimcc/widcc-testsuite.md) | `widcc-slimcc/ctest-work/widcc.tap`、`widcc-slimcc/musl-build/analysis.txt` |
| slimcc | [slimcc-testsuite.md](widcc-slimcc/slimcc-testsuite.md) | `widcc-slimcc/ctest-work/slimcc.tap`、`widcc-slimcc/musl-build-slimcc/analysis.txt` |
| xcc | [xcc-testsuite.md](xcc/xcc-testsuite.md) | `xcc/ctest-work/*.tap`、`xcc/musl-build-*/analysis.txt` |
| 追加包 | 各编译器报告的追加章节；cproc 见 [cproc-report-3.md](cproc-qbe/cproc-report-3.md) | `*/binutils-2.44/build.log`、`*/toybox-0.8.15/build.log` |
| xcc 宿主工具链实验 | [xcc-testsuite.md](xcc/xcc-testsuite.md) 第 9 节 | `xcc/toybox-hostlibc-0.8.15/build*.log`、`xcc/binutils-hostlibc*-2.44/build.log` |

### 9.1 基线评测复现入口

```sh
# cproc host
(cd cproc-qbe/qbe && make -j20)
(cd cproc-qbe/cproc && ./configure --with-qbe="$PWD/../qbe/qbe" && make -j20)

# pcc host
(cd pcc && mkdir -p build-host && cd build-host && ../pcc/configure --prefix="$PWD/../install-host" && make -j20 && make install)

# tcc host
(cd tcc/build-native && ../tinycc/configure --cc=gcc --prefix="$PWD/../install-native" -q && make -j20 && make install)

# widcc / slimcc
(cd widcc-slimcc/widcc && ln -sfn platform/linux-glibc-generic.c platform.c && make -j20)
(cd widcc-slimcc/slimcc && ln -sfn platform/linux-glibc-generic.c platform.c && make -j20)

# xcc host
(cd xcc/build-native && make -j20)

# c-testsuite（以 tcc 为例）
cd c-testsuite
./single-exec ../../../tcc/ctest-work/runners/tcc-native > ../tcc/ctest-work/tcc-native.tap
```

### 9.2 相互构建与 EDG 5.1 的产物

| 项目 | 报告 | 主要结果/日志 |
|---|---|---|
| 相互构建 | [`pairwise/pairwise-build-report.md`](pairwise/pairwise-build-report.md) | `pairwise/builds/*`、`pairwise/logs/*`、`pairwise/xcc-sys/`、`pairwise/wrappers/` |
| EDG 5.1 | [`edg5.1-try/edg5.1-build-report.md`](edg5.1-try/edg5.1-build-report.md) | `edg5.1-try/builds/*`、`edg5.1-try/repro/` |

### 9.3 新增实验的复现入口

```sh
# 四编译器两两互建：以 tcc ← slimcc 为例
cd pairwise/builds/tcc-by-slimcc
../../src/tcc/configure --cc=.../widcc-slimcc/slimcc/slimcc \
  --prefix=$PWD/install --extra-cflags="-O2"
make -j8 && make install

# xcc 回退到系统 as/ld + glibc
cd pairwise/builds/tcc-by-xcc-sys
../../src/tcc/configure --cc=.../pairwise/wrappers/xcc-sys \
  --prefix=$PWD/install --extra-cflags="-O2"
make -j8 && make install

# EDG 5.1：tcc 完整流程（前端 + 运行库 + smoke test）
cd edg5.1-try
NAME=tcc CC=.../tcc/build-native/tcc \
  CFLAGS="-O2 -w -std=gnu89 -fcommon" ./run-edg5.1.sh

# EDG 5.1：cproc + musl 预处理（用于分析 long double 阻塞）
cd edg5.1-try
./run-edg5.1-cproc-musl.sh
```

---
