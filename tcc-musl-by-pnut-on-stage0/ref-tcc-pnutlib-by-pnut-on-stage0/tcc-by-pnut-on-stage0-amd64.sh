


# tcc-by-pnut-on-stage0-amd64.sh
# This can substitute kaem.run or after.kaem.

set -e  -x

########## Prepare & Run ##############

### Prepare the rootfs environment (clone, update submodules, edit files, apply patches)
# ./prepare-rootfs.sh

### Run in chroot/bwrap
# ./bootstrap-seeds/POSIX/AMD64/kaem-optional-seed ./kaem.amd64


########## Config #########################################

# Use what artifact in stage0-posix
# Here we use earlier version of each utility, so we don't need the original kaem.run,
# which runs mescc-tools-{full,extra}-kaem.kaem, and can substitute it.
# You can use newer versions as well, that shall not affect the product's sha256sum.

ARTIFACT=./build

# [ M2, M2-Planet ]
M2=${ARTIFACT}/M2
# (blood-elf-0, blood-elf)
BLOOD=${ARTIFACT}/blood-elf-0
# (M1-0, M1)
M1=${ARTIFACT}/M1-0
# (hex2-1, hex2)
HEX2=${ARTIFACT}/hex2-1

M2LIB=./stage0/M2libc

BUILD=./build

PNUT=./pnut

# (AMD64, x86)



echo "############### Building pnut ###############"

# For (AMD64, x86) * (STG-v1, STG-v2) => tcc-boot3 37afc
# This amd64 script reaches the same kind of fixed point, with
# tcc-boot2 = tcc-boot3 = b6bc9b3d0c0635476dac371d1864fd219e7b6ae2455ad7910dc620033c0707a3

# Use M2-Planet to build pnut-exe-by-M2-Planet
# On amd64, M2-Planet's int is 8 bytes, while pnut's integer overflow check
# assumes a 32-bit int: it compares the previous literal's leftover `val`
# against a 32-bit limit while tokenizing directives such as `#define X 1`.
# Disable the check for this seed compiler (pnut's kit/bootstrap.sh disables it
# for its c4 seed for the same reason); the next stages are built by pnut,
# whose int is 4 bytes, and do have the check.
${M2} --architecture amd64 -D target_x86_64_linux -D NO_TERNARY_SUPPORT -D ONE_PASS_GENERATOR -D SMALL_HEAP -D NO_SUPPORT_TENTATIVE_DECLS -D DISABLE_INTEGER_OVERFLOW_CHECK -I ${M2LIB} --expand-includes --debug ${PNUT}/pnut.c -o ${BUILD}/pnut.M1

# blood-elf needs --64 to emit 64-bit pointers for the amd64 footer.
${BLOOD} --64 -f ${BUILD}/pnut.M1 --little-endian --entry _start -o ${BUILD}/pnut-footer.M1

${M1} -f ${M2LIB}/amd64/amd64_defs.M1 -f ${M2LIB}/amd64/libc-full.M1 -f ${BUILD}/pnut.M1 -f ${BUILD}/pnut-footer.M1 --architecture amd64 --little-endian -o ${BUILD}/pnut.hex2

# 0x00600000 is the base address stage0-posix uses for amd64 (see
# stage0/AMD64/mescc-tools-mini-kaem.kaem); the i386 value is 0x8048000.
${HEX2} --architecture amd64 --little-endian --file ${M2LIB}/amd64/ELF-amd64-debug.hex2 --file ${BUILD}/pnut.hex2 --base-address 0x00600000 --output ${BUILD}/pnut-exe-by-M2-Planet

# Recompile pnut with itself
#${BUILD}/pnut ${PNUT}/pnut.c -Dtarget_x86_64_linux -D ONE_PASS_GENERATOR -o ${BUILD}/pnut-exe-by-pnut-exe

# Build pnut-exe which can be used to build tinycc
# (Modified from pnut/kit/setup-rootfs)
${BUILD}/pnut-exe-by-M2-Planet ${PNUT}/pnut.c \
  -Dtarget_x86_64_linux \
  -DONE_PASS_GENERATOR \
  -DUNDEFINED_LABELS_ARE_RUNTIME_ERRORS \
  -DENABLE_PNUT_INLINE_INTERRUPT \
  -DNO_BUILTIN_LIBC \
  -o ${BUILD}/pnut-exe-0

# 64-bit integers are native on amd64, so SUPPORT_EMULATED_INT64 and the
# arith64.c runtime are not needed (pnut/kit/bootstrap.sh does the same).
# Compiling TCC's x86-64 backend needs a bigger AST heap and program size than
# the 768K-word / 1MB defaults; these values are the ones pnut/kit/bootstrap.sh
# uses (2000 * 1024 words for the heap, 2000 * 1024 bytes for the code).
${BUILD}/pnut-exe-0 ${PNUT}/pnut.c \
  -Dtarget_x86_64_linux \
  -DONE_PASS_GENERATOR \
  -DHEAP_SIZE=2048000 -DMAX_CODE_SIZE=2048000 -DPROGRAM_SIZE=2048000 \
  -DUNDEFINED_LABELS_ARE_RUNTIME_ERRORS \
  -DENABLE_PNUT_INLINE_INTERRUPT \
  -DNO_BUILTIN_LIBC \
  -I ${PNUT}/portable_libc/include/ \
  ${PNUT}/portable_libc/libc.c \
  -o ${BUILD}/pnut-exe

${BUILD}/pnut-exe ${PNUT}/pnut.c \
  -Dtarget_x86_64_linux \
  -DONE_PASS_GENERATOR \
  -DHEAP_SIZE=2048000 -DMAX_CODE_SIZE=2048000 -DPROGRAM_SIZE=2048000 \
  -DUNDEFINED_LABELS_ARE_RUNTIME_ERRORS \
  -DENABLE_PNUT_INLINE_INTERRUPT \
  -DNO_BUILTIN_LIBC \
  -I ${PNUT}/portable_libc/include/ \
  ${PNUT}/portable_libc/libc.c \
  -o ${BUILD}/pnut-exe-self



echo "############### Building bintools ###############"

# Code below is mainly modified from pnut/kit/bootstrap.sh

# (1) pnut compiles positional files last-to-first (-rt is compiled first).
# (2) Only one -I is accepted by pnut, and the path must end with '/'

# build bintools

${BUILD}/pnut-exe -I ${PNUT}/portable_libc/include/ \
  ${PNUT}/kit/bintools.c \
  ${PNUT}/portable_libc/src/string.c \
  ${PNUT}/portable_libc/src/stdlib.c \
  ${PNUT}/portable_libc/src/stdio.c \
  ${PNUT}/portable_libc/src/setjmp.c \
  ${PNUT}/portable_libc/src/pnut_lib.c \
  ${PNUT}/portable_libc/src/math.c \
  -o ${BUILD}/bintools

${BUILD}/bintools sha256sum ${BUILD}/bintools



echo "############### Applying patches to tcc ###############"

# Code below is mainly modified from pnut/kit/bootstrap.sh

TCC_VERSION=0.9.27
TCC_ARCHIVE=${PNUT}/kit/tcc-0.9.27.tar.gz
TCC_DIR=tcc-0.9.27
PATCHES_DIR=${PNUT}/kit/tcc-patches/0.9.27

# Unpack tcc (bintools provides ungz/untar/cp; a kaem rootfs has none of them)
cd ${BUILD}
./bintools ungz --file ../${TCC_ARCHIVE} --output ./tcc-${TCC_VERSION}.tar
./bintools untar ./tcc-${TCC_VERSION}.tar
./bintools cp ../${PNUT}/kit/config.h ${TCC_DIR}/config.h

# Apply TCC Patches

# [tccpp.c] PNUT_CC char buf1[sizeof file->filename] => char buf1[1024] (no sizeof)
./bintools simple-patch ${TCC_DIR}/tccpp.c ../${PATCHES_DIR}/array_sizeof.before ../${PATCHES_DIR}/array_sizeof.after
# [tcc.h] PNUT_CC NORETURN, ALIGNED(x) = [SPACE] (no __attribute__)
./bintools simple-patch ${TCC_DIR}/tcc.h ../${PATCHES_DIR}/attribute.before ../${PATCHES_DIR}/attribute.after
# [tcc.h] Put SymAttr/FuncAttr's bitfield in HAVE_BITFIELD
./bintools simple-patch ${TCC_DIR}/tcc.h ../${PATCHES_DIR}/bitfields.before ../${PATCHES_DIR}/bitfields.after
# [tccgen.c] -1.0 * 0.0, f2 == 0.0: #if HAVE_FLOAT
./bintools simple-patch ${TCC_DIR}/tccgen.c ../${PATCHES_DIR}/float_negation.before ../${PATCHES_DIR}/float_negation.after
./bintools simple-patch ${TCC_DIR}/tccgen.c ../${PATCHES_DIR}/float_zero_division_check.before ../${PATCHES_DIR}/float_zero_division_check.after
# [tccgen.c] VT_LDOUBLE long double #ifdef HAVE_FLOAT
./bintools simple-patch ${TCC_DIR}/tccgen.c ../${PATCHES_DIR}/long_double_codegen.before ../${PATCHES_DIR}/long_double_codegen.after
# [tccpp.c] scientific-notation (double)bn[1] * 4294967296.0 + bn[0] #ifdef HAVE_FLOAT
./bintools simple-patch ${TCC_DIR}/tccpp.c ../${PATCHES_DIR}/scientific-notation-parser.before ../${PATCHES_DIR}/scientific-notation-parser.after
# [libtcc.c] sscanf(TCC_VERSION,"%d.%d.%d",...) => a=0;b=9;c=27
./bintools simple-patch ${TCC_DIR}/libtcc.c ../${PATCHES_DIR}/sscanf_TCC_VERSION.before ../${PATCHES_DIR}/sscanf_TCC_VERSION.after
# Extra patches needed by TCC's x86-64 backend (see TCC_X86_64_PATCHES in
# pnut/kit/bootstrap.sh):
# [x86_64-gen.c] enum __va_arg_type declared in a function body => #define
./bintools simple-patch ${TCC_DIR}/x86_64-gen.c ../${PATCHES_DIR}/x86_64_va_arg_local_enum.before ../${PATCHES_DIR}/x86_64_va_arg_local_enum.after
# [x86_64-gen.c] char _onstack[nb_args] VLA => fixed size array
./bintools simple-patch ${TCC_DIR}/x86_64-gen.c ../${PATCHES_DIR}/x86_64_gfunc_call_vla.before ../${PATCHES_DIR}/x86_64_gfunc_call_vla.after
# [tccelf.c] static x86-64 PLT calls: R_X86_64_PLT32 => R_X86_64_PC32
./bintools simple-patch ${TCC_DIR}/tccelf.c ../${PATCHES_DIR}/x86_64_static_plt_call.before ../${PATCHES_DIR}/x86_64_static_plt_call.after
# [tccelf.c] static x86-64 GOT relocations
./bintools simple-patch ${TCC_DIR}/tccelf.c ../${PATCHES_DIR}/x86_64_static_got_reloc.before ../${PATCHES_DIR}/x86_64_static_got_reloc.after



cd ..


echo "##### ##### ##### Building tcc-pnut ##### ##### #####"


# kaem strips the "" pair but keeps the '' as literal characters, so
# -D X='"/"' would define X as '/', while X=\"/\" gives "/" in both
# kaem and bash (bash drops the backslashes).
# In kaem, the next line after '\' must begin with space/tab.
${BUILD}/pnut-exe \
  -D BOOTSTRAP=1 \
  -D PNUT_CC=1 \
  -D HAVE_LONG_LONG=1 \
  -D TCC_TARGET_X86_64=1 \
  -D CONFIG_SYSROOT=\"/\" \
  -D CONFIG_TCC_CRTPREFIX=\"build/boot0-lib\" \
  -D CONFIG_TCC_ELFINTERP=\"build/loader\" \
  -D CONFIG_TCC_SYSINCLUDEPATHS=\"pnut/portable_libc/include\" \
  -D TCC_LIBGCC=\"build/boot0-lib/libc.a\" \
  -D CONFIG_TCC_LIBTCC1_MES=0 \
  -D CONFIG_TCCBOOT=1 \
  -D CONFIG_TCC_STATIC=1 \
  -D CONFIG_USE_LIBGCC=1 \
  -D TCC_VERSION=\"0.9.27\" \
  -D ONE_SOURCE=1 \
  -D CONFIG_TCCDIR=\"build/boot0-lib/tcc\" \
  build/tcc-0.9.27/tcc.c \
  -I pnut/portable_libc/include/ pnut/portable_libc/libc.c \
  -D __intptr_t_defined=1 \
  -o build/tcc-pnut

echo "##### ##### ##### Building tcc-boot0..3 ##### ##### #####"

# Code below is mainly modified from pnut/kit/bootstrap.sh (its go() function).
# NOTE: CONFIG_TCC_LIBPATHS keeps this script's historical value
#       "${LIBPATH}:/tcc" (upstream renamed the variable to LIB_PATH; using
#       ${LIBPATH}/tcc here changes every tcc-boot* hash).

# ---- round 0: build/tcc-pnut builds build/tcc-boot0 (libraries in build/boot0-lib) ----
CC=./build/tcc-pnut
TCC_OUT=build/tcc-boot0
LIBPATH=build/boot0-lib

${BUILD}/bintools mkdir -p ${LIBPATH}
${BUILD}/bintools mkdir -p ${LIBPATH}/tcc

${CC} -c ${PNUT}/portable_libc/src/crt1.c -o ${LIBPATH}/crt1.o
${BUILD}/bintools cp /dev/null ${LIBPATH}/crtn.o
${BUILD}/bintools cp /dev/null ${LIBPATH}/crti.o
${CC} -c -D ADD_LIBC_STUB -I ${PNUT}/portable_libc/include -o ${LIBPATH}/libc.o ${PNUT}/portable_libc/libc.c
${CC} -ar -cr ${LIBPATH}/libc.a ${LIBPATH}/libc.o
${CC} -c -o ${LIBPATH}/libtcc1.o ${PNUT}/kit/libtcc1.c
# TCC's x86-64 backend implements __va_start/__va_arg in lib/va_list.c and
# upstream puts that object in libtcc1.a too (see lib/Makefile, OBJ-x86_64).
${CC} -c -o ${LIBPATH}/va_list.o build/tcc-0.9.27/lib/va_list.c
${CC} -ar -cr ${LIBPATH}/tcc/libtcc1.a ${LIBPATH}/libtcc1.o ${LIBPATH}/va_list.o

${CC} \
	-v \
	-static \
	-o ${TCC_OUT} \
	-D BOOTSTRAP=1 \
	-D __SIZEOF_LONG_LONG__=8 \
	-D HAVE_FLOAT=1 \
	-D HAVE_BITFIELD=1 \
	-D HAVE_LONG_LONG=1 \
	-D HAVE_SETJMP=1 \
	-I ${PNUT}/portable_libc/include \
	-D TCC_TARGET_X86_64=1 \
	-D CONFIG_TCCDIR=\"${LIBPATH}/tcc\" \
	-D CONFIG_TCC_CRTPREFIX=\"${LIBPATH}\" \
	-D CONFIG_TCC_LIBPATHS=\"${LIBPATH}:/tcc\" \
	-D CONFIG_TCC_SYSINCLUDEPATHS=\"${PNUT}/portable_libc/include\" \
	-D TCC_LIBGCC=\"${LIBPATH}/libc.a\" \
	-D TCC_LIBTCC1=\"libtcc1.a\" \
	-D CONFIG_TCC_ELFINTERP=\"/mes/loader\" \
	-D CONFIG_TCCBOOT=1 \
	-D CONFIG_TCC_STATIC=1 \
	-D CONFIG_USE_LIBGCC=1 \
	-D TCC_VERSION=\"0.9.27\" \
	-D ONE_SOURCE=1 \
	-L ${LIBPATH} \
	build/tcc-0.9.27/tcc.c

# ---- round 1: build/tcc-boot0 builds build/tcc-boot1 (libraries in build/boot1-lib) ----
CC=./build/tcc-boot0
TCC_OUT=build/tcc-boot1
LIBPATH=build/boot1-lib

${BUILD}/bintools mkdir -p ${LIBPATH}
${BUILD}/bintools mkdir -p ${LIBPATH}/tcc

${CC} -c ${PNUT}/portable_libc/src/crt1.c -o ${LIBPATH}/crt1.o
${BUILD}/bintools cp /dev/null ${LIBPATH}/crtn.o
${BUILD}/bintools cp /dev/null ${LIBPATH}/crti.o
${CC} -c -D ADD_LIBC_STUB -I ${PNUT}/portable_libc/include -o ${LIBPATH}/libc.o ${PNUT}/portable_libc/libc.c
${CC} -ar -cr ${LIBPATH}/libc.a ${LIBPATH}/libc.o
${CC} -c -o ${LIBPATH}/libtcc1.o ${PNUT}/kit/libtcc1.c
# TCC's x86-64 backend implements __va_start/__va_arg in lib/va_list.c and
# upstream puts that object in libtcc1.a too (see lib/Makefile, OBJ-x86_64).
${CC} -c -o ${LIBPATH}/va_list.o build/tcc-0.9.27/lib/va_list.c
${CC} -ar -cr ${LIBPATH}/tcc/libtcc1.a ${LIBPATH}/libtcc1.o ${LIBPATH}/va_list.o

${CC} \
	-v \
	-static \
	-o ${TCC_OUT} \
	-D BOOTSTRAP=1 \
	-D __SIZEOF_LONG_LONG__=8 \
	-D HAVE_FLOAT=1 \
	-D HAVE_BITFIELD=1 \
	-D HAVE_LONG_LONG=1 \
	-D HAVE_SETJMP=1 \
	-I ${PNUT}/portable_libc/include \
	-D TCC_TARGET_X86_64=1 \
	-D CONFIG_TCCDIR=\"${LIBPATH}/tcc\" \
	-D CONFIG_TCC_CRTPREFIX=\"${LIBPATH}\" \
	-D CONFIG_TCC_LIBPATHS=\"${LIBPATH}:/tcc\" \
	-D CONFIG_TCC_SYSINCLUDEPATHS=\"${PNUT}/portable_libc/include\" \
	-D TCC_LIBGCC=\"${LIBPATH}/libc.a\" \
	-D TCC_LIBTCC1=\"libtcc1.a\" \
	-D CONFIG_TCC_ELFINTERP=\"/mes/loader\" \
	-D CONFIG_TCCBOOT=1 \
	-D CONFIG_TCC_STATIC=1 \
	-D CONFIG_USE_LIBGCC=1 \
	-D TCC_VERSION=\"0.9.27\" \
	-D ONE_SOURCE=1 \
	-L ${LIBPATH} \
	build/tcc-0.9.27/tcc.c

# ---- round 2: build/tcc-boot1 builds build/tcc-boot2 (libraries in build/boot2-lib) ----
CC=./build/tcc-boot1
TCC_OUT=build/tcc-boot2
LIBPATH=build/boot2-lib

${BUILD}/bintools mkdir -p ${LIBPATH}
${BUILD}/bintools mkdir -p ${LIBPATH}/tcc

${CC} -c ${PNUT}/portable_libc/src/crt1.c -o ${LIBPATH}/crt1.o
${BUILD}/bintools cp /dev/null ${LIBPATH}/crtn.o
${BUILD}/bintools cp /dev/null ${LIBPATH}/crti.o
${CC} -c -D ADD_LIBC_STUB -I ${PNUT}/portable_libc/include -o ${LIBPATH}/libc.o ${PNUT}/portable_libc/libc.c
${CC} -ar -cr ${LIBPATH}/libc.a ${LIBPATH}/libc.o
${CC} -c -o ${LIBPATH}/libtcc1.o ${PNUT}/kit/libtcc1.c
# TCC's x86-64 backend implements __va_start/__va_arg in lib/va_list.c and
# upstream puts that object in libtcc1.a too (see lib/Makefile, OBJ-x86_64).
${CC} -c -o ${LIBPATH}/va_list.o build/tcc-0.9.27/lib/va_list.c
${CC} -ar -cr ${LIBPATH}/tcc/libtcc1.a ${LIBPATH}/libtcc1.o ${LIBPATH}/va_list.o

${CC} \
	-v \
	-static \
	-o ${TCC_OUT} \
	-D BOOTSTRAP=1 \
	-D __SIZEOF_LONG_LONG__=8 \
	-D HAVE_FLOAT=1 \
	-D HAVE_BITFIELD=1 \
	-D HAVE_LONG_LONG=1 \
	-D HAVE_SETJMP=1 \
	-I ${PNUT}/portable_libc/include \
	-D TCC_TARGET_X86_64=1 \
	-D CONFIG_TCCDIR=\"${LIBPATH}/tcc\" \
	-D CONFIG_TCC_CRTPREFIX=\"${LIBPATH}\" \
	-D CONFIG_TCC_LIBPATHS=\"${LIBPATH}:/tcc\" \
	-D CONFIG_TCC_SYSINCLUDEPATHS=\"${PNUT}/portable_libc/include\" \
	-D TCC_LIBGCC=\"${LIBPATH}/libc.a\" \
	-D TCC_LIBTCC1=\"libtcc1.a\" \
	-D CONFIG_TCC_ELFINTERP=\"/mes/loader\" \
	-D CONFIG_TCCBOOT=1 \
	-D CONFIG_TCC_STATIC=1 \
	-D CONFIG_USE_LIBGCC=1 \
	-D TCC_VERSION=\"0.9.27\" \
	-D ONE_SOURCE=1 \
	-L ${LIBPATH} \
	build/tcc-0.9.27/tcc.c

# ---- round 3: build/tcc-boot2 builds build/tcc-boot3 (libraries in build/boot2-lib) ----
CC=./build/tcc-boot2
TCC_OUT=build/tcc-boot3
LIBPATH=build/boot2-lib

${BUILD}/bintools mkdir -p ${LIBPATH}
${BUILD}/bintools mkdir -p ${LIBPATH}/tcc

${CC} -c ${PNUT}/portable_libc/src/crt1.c -o ${LIBPATH}/crt1.o
${BUILD}/bintools cp /dev/null ${LIBPATH}/crtn.o
${BUILD}/bintools cp /dev/null ${LIBPATH}/crti.o
${CC} -c -D ADD_LIBC_STUB -I ${PNUT}/portable_libc/include -o ${LIBPATH}/libc.o ${PNUT}/portable_libc/libc.c
${CC} -ar -cr ${LIBPATH}/libc.a ${LIBPATH}/libc.o
${CC} -c -o ${LIBPATH}/libtcc1.o ${PNUT}/kit/libtcc1.c
# TCC's x86-64 backend implements __va_start/__va_arg in lib/va_list.c and
# upstream puts that object in libtcc1.a too (see lib/Makefile, OBJ-x86_64).
${CC} -c -o ${LIBPATH}/va_list.o build/tcc-0.9.27/lib/va_list.c
${CC} -ar -cr ${LIBPATH}/tcc/libtcc1.a ${LIBPATH}/libtcc1.o ${LIBPATH}/va_list.o

${CC} \
	-v \
	-static \
	-o ${TCC_OUT} \
	-D BOOTSTRAP=1 \
	-D __SIZEOF_LONG_LONG__=8 \
	-D HAVE_FLOAT=1 \
	-D HAVE_BITFIELD=1 \
	-D HAVE_LONG_LONG=1 \
	-D HAVE_SETJMP=1 \
	-I ${PNUT}/portable_libc/include \
	-D TCC_TARGET_X86_64=1 \
	-D CONFIG_TCCDIR=\"${LIBPATH}/tcc\" \
	-D CONFIG_TCC_CRTPREFIX=\"${LIBPATH}\" \
	-D CONFIG_TCC_LIBPATHS=\"${LIBPATH}:/tcc\" \
	-D CONFIG_TCC_SYSINCLUDEPATHS=\"${PNUT}/portable_libc/include\" \
	-D TCC_LIBGCC=\"${LIBPATH}/libc.a\" \
	-D TCC_LIBTCC1=\"libtcc1.a\" \
	-D CONFIG_TCC_ELFINTERP=\"/mes/loader\" \
	-D CONFIG_TCCBOOT=1 \
	-D CONFIG_TCC_STATIC=1 \
	-D CONFIG_USE_LIBGCC=1 \
	-D TCC_VERSION=\"0.9.27\" \
	-D ONE_SOURCE=1 \
	-L ${LIBPATH} \
	build/tcc-0.9.27/tcc.c


${BUILD}/bintools sha256sum build/tcc-boot0 build/tcc-boot1 build/tcc-boot2 build/tcc-boot3

echo "This is the end of the script."
