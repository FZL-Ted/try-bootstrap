# base-pnut：用 Onramp 构建 pnut 与 TCC

本目录用于验证自举构建出的 [Onramp](../base-onramp/onramp) C 工具链，按顺序构建：

1. `pnut-exe`：pnut 的原生代码后端；
2. TCC 0.9.27：pnut 自带 `kit/` 中的版本；
3. tinycc commit `fc1fc50f`（版本 0.9.28rc）：`./tinycc`
   （指向 `../tcc/tinycc` 的符号链接）。

共有三个脚本：

| 脚本 | 作用 |
|---|---|
| `onramp-to-pnut-exe.sh` | 用 Onramp 编译 `pnut.c`，验证原生 ELF 输出与 pnut 自举固定点 |
| `onramp-pnut-tcc-0.9.27.sh` | 用第 1 步的 pnut 构建 `pnut/kit/tcc-0.9.27.tar.gz` 中的 TCC 0.9.27，验证 hello 和 TCC 自编译 |
| `onramp-pnut-tcc-fc1fc50f-20261120.sh` | 用第 1 步的 pnut 构建 `./tinycc` 中的 tinycc `fc1fc50f`（0.9.28rc），需要 `patches/` 中的补丁 |

## 应该用哪个脚本？

- **只需要 pnut**：运行 `./onramp-to-pnut-exe.sh`。
- **需要 pnut 自带的 TCC 版本**：先运行一次
  `./onramp-to-pnut-exe.sh`，再运行 `./onramp-pnut-tcc-0.9.27.sh`。
- **需要较新的 tinycc（0.9.28rc，"tinycc (lnk)"）**：先运行一次
  `./onramp-to-pnut-exe.sh`，再运行
  `./onramp-pnut-tcc-fc1fc50f-20261120.sh`。该脚本假定
  `build-onramp-exe/pnut-exe-by-pnut-exe` 已存在，**不会**重新构建 pnut-exe。

三个脚本都使用 `../base-onramp/onramp` 中构建好的 Onramp 工具链（见
[report-onramp.md](../base-onramp/report-onramp.md)）。原始 `pnut/` 和
`tinycc/` 源码树不会被修改，脚本只在各自的构建目录中复制并打补丁。

宿主要求：x86_64 Linux、`bash`、`tar`、`realpath`，以及 `patch` 或 `git`
（应用统一补丁）。不再需要宿主 C 编译器（`gcc`）或 binutils。

---

## 1. `onramp-to-pnut-exe.sh`

用 Onramp 编译 `pnut.c`，选择原生 ELF 后端，并验证：

1. `pnut-exe` 编译的小程序可以原生运行（退出码 42）；
2. `pnut-exe` 能把 `pnut.c` 编译成原生 pnut；
3. 原生 pnut 再编译 `pnut.c`，得到逐字节相同的二进制（固定点）。

```sh
./onramp-to-pnut-exe.sh                    # x86_64（默认）
./onramp-to-pnut-exe.sh --target i386      # 32 位，M2-Planet 风格
./onramp-to-pnut-exe.sh --force            # 强制重建
```

关键选项：

```sh
-Dtarget_x86_64_linux   # 或 -Dtarget_i386_linux
-DONE_PASS_GENERATOR
```

`ONE_PASS_GENERATOR` 在 Onramp 下是必需的。不加时 `exe.c` 会分配
`CODE_SIZE = 5,000,000` 个 `int`（20 MB），超过 Onramp VM 的 16 MiB 自由内存区，
运行 `pnut-exe` 会报 `ERROR: A memory access is invalid.`；加上后
`CODE_SIZE` 为 200,000（800 KB）。

产物（`build-onramp-exe/`）：

| 文件 | 说明 |
|---|---|
| `pnut-exe` | Onramp 编译出的 pnut（运行在 Onramp VM 上，需要 `onrampvm` 在 `PATH`） |
| `pnut-exe-by-pnut-exe` | `pnut-exe` 编译 `pnut.c` 得到的原生 pnut |
| `pnut-exe-by-pnut-exe-2` | 原生 pnut 再编译 `pnut.c` 的结果，必须与前一代相同 |
| `tiny.c`、`tiny`、`tiny-native` | 退出码冒烟测试 |

实测结果：

| 目标 | Onramp 版 `pnut-exe` | 原生 pnut | 固定点 SHA-256 |
|---|---:|---:|---|
| x86_64 | 436,952 B | 237,279 B | `ad17e277…b36e13a8` |
| i386 | 459,120 B | 214,805 B | `31186a4b…a76a06a` |

i386 版本使用 pnut 的软件 64 位算术（`-DSUPPORT_EMULATED_INT64` +
`arith64.c`），因此其二进制与 x86_64 不同。

---

## 2. `onramp-pnut-tcc-0.9.27.sh`

用第 1 步的 pnut，按 `pnut/kit/bootstrap.sh` 的流程构建
`pnut/kit/tcc-0.9.27.tar.gz` 中的 TCC 0.9.27：

1. 重新编译 `pnut.c`，启用 `-DNO_BUILTIN_LIBC -DSAFE_MODE` 并链接
   `portable_libc/libc.c`，得到 `pnut-exe-for-tcc`；
2. 解压 TCC 0.9.27，安装 `kit/config.h`，应用统一补丁
   `patches/tcc-0.9.27-pnut.patch`（x86_64 另加
   `patches/tcc-0.9.27-pnut-x86_64.patch`）；
3. 编译 `tcc.c` + `portable_libc/libc.c`，得到 `tcc-pnut`；
4. 构建 boot0 运行库（`crt1.o`、`libc.a`、`libtcc1.a`），用 `tcc-pnut`
   编译并运行 `hello`；
5. 用 `tcc-pnut` 自编译 TCC，得到 `tcc-boot0` 并运行。

```sh
./onramp-pnut-tcc-0.9.27.sh                    # x86_64
./onramp-pnut-tcc-0.9.27.sh --target i386      # i386
./onramp-pnut-tcc-0.9.27.sh --force            # 先重建 pnut-exe
```

产物（`build-pnut-tcc/`）：`pnut-exe-for-tcc`、打补丁的 `tcc-0.9.27/`、
`build/tcc-pnut`、`build/tcc-boot0`、`build/boot0-lib/`、`build/hello`。

实测结果：

| 目标 | `tcc-pnut` | `tcc-boot0` | 版本输出 |
|---|---:|---:|---|
| x86_64 | 1,280,725 B | 304,040 B | `tcc version 0.9.27 (x86_64 Linux)` |
| i386 | 978,221 B | 238,912 B | `tcc version 0.9.27 (i386 Linux)` |

`tcc-pnut` 能编译并运行 `hello`；`tcc-boot0` 是 TCC 自编译的版本，也能运行。
在已构建 pnut-exe 的前提下，整个脚本约 12 秒（x86_64）；`--force`（同时重建
pnut-exe）约 52 秒。日志见 [pnut-tcc-self-test.log](pnut-tcc-self-test.log)。

---

## 3. `onramp-pnut-tcc-fc1fc50f-20261120.sh`

用第 1 步的 pnut 构建 `./tinycc` 中较新的 tinycc（commit `fc1fc50f`，版本
0.9.28rc）。该脚本只支持 x86_64 的 pnut-exe。**该脚本假定 `./onramp-to-pnut-exe.sh` 已经执行过**，以
`build-onramp-exe/pnut-exe-by-pnut-exe` 为种子编译器，不会重建 pnut-exe。

```sh
./onramp-to-pnut-exe.sh                       # 先执行一次
./onramp-pnut-tcc-fc1fc50f-20261120.sh        # 构建 tinycc
```

产物（`build-pnut-tinycc/`）：

| 路径 | 说明 |
|---|---|
| `C1`、`pnut-exe-for-tcc` | 两阶段 pnut 引导编译器 |
| `tcc-src/` | 已打补丁的 tinycc 源码 |
| `bin/tcc-pnut` | pnut 编译出的 tinycc 0.9.28rc（1,691,884 B） |
| `bin/crt1.o`、`bin/libc.o`、`bin/libtcc1.o`、`bin/va_list.o` | `tcc-pnut` 构建的运行库目标文件 |
| `bin/tiny`、`bin/hello` | 由 `tcc-pnut` 自己链接出的可执行文件 |

实测结果（x86_64）：

```
tcc version 0.9.28rc (x86_64 Linux)
tcc-pnut compiled tiny.c to 1134 bytes
tcc-pnut compiled and linked tiny (exit 42)
tcc-pnut compiled and linked hello:
  Hello from tinycc 0.9.28rc built by pnut!
```

在 pnut-exe 已存在的前提下，整个脚本约 4 秒完成。日志见
[pnut-tinycc-self-test.log](pnut-tinycc-self-test.log)。

### 为什么需要额外补丁？

tinycc 0.9.28rc 比 pnut `kit/` 支持的版本新，`patches/` 中存放了移植补丁：

- `patches/tinycc-fc1fc50f-pnut.patch` —— tinycc 源码修改：
  - `PNUT_CC` 下固定 `LDOUBLE_WORDS`（pnut 不能在数组长度中使用 `sizeof`）；
  - 未定义 `HAVE_BITFIELD` 时，把 `SymAttr`、`FuncAttr`、`sym_attr` 的位域
    改成普通字段（pnut 不支持位域声明）；
  - `PNUT_CC` 下把 `NORETURN`、`ALIGNED`、`PRINTF_LIKE` 定义为空；
  - `ldexpl` 映射到 `ldexp`（portable libc 没有 `ldexpl`）；
  - 为 `CONFIG_TCC_SEMLOCK` 提供空的 `TCCSem`（portable libc 没有
    `<semaphore.h>`）；
  - 直接定义 `TCC_STATE_VAR` 状态别名，避免自引用宏展开（pnut 不会展开
    出现在自身展开中的宏名）；
  - `tcc_internal_error` 不使用 `__FUNCTION__`；
  - `tccpp.c`/`tccgen.c` 中的浮点字面量代码用 `HAVE_FLOAT` 保护
    （pnut 不支持浮点字面量）；
  - `N_DEFAULT_DEBUG` 固定为 29/27 项（pnut 不能对变量求 `sizeof`）；
  - `tccrun.c` 中不使用 `environ`、`freopen`；
  - `libtcc.h` 的 `jmp_buf` 参数改名（portable libc 把 `jmp_buf` 定义成宏）；
  - 应用 pnut `kit/tcc-patches/0.9.27` 中的 x86-64 局部 enum 的 `va_arg` 补丁。
- `patches/tcc-0.9.27-pnut.patch`、`patches/tcc-0.9.27-pnut-x86_64.patch`
  —— 把 `kit/tcc-patches/0.9.27/*.before/.after` 转成统一 diff；脚本 2 用它
  应用补丁，不再依赖 `python3`。
- `patches/pnut-portable-libc.patch` —— 用 `!PNUT_PORTABLE_LIBC` 保护 pnut
  自带的 `strlen`/`memcpy`/`strrchr`，避免与 `portable_libc` 冲突。
- `patches/pnut-tcc-compat.c` —— 补充 tinycc 用到、但 portable libc 缺少的
  `strpbrk`、`strerror`，以及一个直接退出的 `longjmp`。

### 两阶段 pnut 引导

作为种子的原生 pnut 仍会生成 pnut 内建运行时（包括 `printf` 桩）。如果直接用
它加 `-DNO_BUILTIN_LIBC` 构建 `pnut-exe-for-tcc`，内建运行时和 portable libc
会混在一起（`strlen` 重复定义、`printf` 使用桩）。因此脚本分两步：

- **C1**：种子 pnut 编译 `pnut.c`，定义 `-DNO_BUILTIN_LIBC`，但不链接
  portable libc（C1 自身运行时仍来自种子）；
- **C2**：C1 编译 `pnut.c`，定义 `-DNO_BUILTIN_LIBC -DPNUT_PORTABLE_LIBC`
  并链接 `portable_libc/libc.c`，得到 `pnut-exe-for-tcc`。

C2 有可用的错误诊断，且不再生成内建运行时，用于编译 tinycc。

### 验证与限制

`tcc-pnut` 能把 C 编译成 x86-64 ELF 目标文件。脚本先用 `tcc-pnut` 构建运行库
目标文件（`crt1.o`、`libc.o`、`libtcc1.o`、`va_list.o`），再用它自己链接：

```sh
tcc-pnut -nostdlib -static -o tiny \
    crt1.o libc.o libtcc1.o va_list.o tiny.o
```

整个 tinycc 构建与验证过程都不使用宿主 C 编译器或 binutils。

仍然不支持 archive（`-l`）链接：pnut 的 portable libc 缺少 TCC 归档读取器
依赖的 stdio/归档行为，TCC 报 `invalid archive`；TCC 自带 `-ar` 的输出可被
宿主 `ar` 接受，但会被 TCC 自己的链接器拒绝。这是 pnut 的移植限制，不是
tinycc 构建失败。因此脚本使用 `CONFIG_TCC_BACKTRACE=0`（不引入
`ucontext`/回溯），也未测试 TCC 的 `-run`。

---

## 三个脚本共同的技术点

1. **不使用 `onrampcc`。** 源码树内的 `onrampcc` 会传入包含多个 `..` 和符号
   链接的 include 路径，导致 Onramp cpp 报
   `Internal error: Invalid format output.`。脚本直接调用
   `output/final/bin/cc.oe`，并用 `realpath` 规范化 wrap-header 路径。
2. **Onramp 链接器的 `#line` 文件名上限为 128 字节。** Onramp 头文件的绝对
   路径更长，因此脚本在预处理后把绝对路径改写为 basename（否则报
   `Name is too long.`）。
3. **ISO C 严格检查。** pnut 的 `set_car()`/`set_cdr()` 中
   `return void_expression;` 是 GCC 扩展，Onramp 会拒绝；构建副本中改为
   普通调用语句。

## 复现

```sh
# 1. 构建 Onramp（一次）
cd ../base-onramp/onramp && ./configure.sh && ./build.sh
cd ../../base-pnut

# 2. pnut
./onramp-to-pnut-exe.sh

# 3. pnut 自带的 TCC
./onramp-pnut-tcc-0.9.27.sh

# 4. tinycc fc1fc50f（需要先执行第 2 步）
./onramp-pnut-tcc-fc1fc50f-20261120.sh
```

所有构建产物位于 `build-onramp-exe/`、`build-pnut-tcc/`、
`build-pnut-tinycc/`；原始 `pnut/` 和 `tinycc/` 源码树保持干净。
