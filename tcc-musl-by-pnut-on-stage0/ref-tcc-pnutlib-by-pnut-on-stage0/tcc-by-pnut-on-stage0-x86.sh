


# tcc-by-pnut-on-stage0.sh
# This can substitute kaem.run or after.kaem.

set -e  -x

########## Prepare & Run ##############

### Prepare the rootfs environment (clone, update submodules, edit files, apply patches)
# ./prepare-rootfs.sh

### Run in chroot/bwrap
# ./bootstrap-seeds/POSIX/x86/kaem-optional-seed ./kaem.x86


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

# Use M2-Planet to build pnut-exe-by-M2-Planet
${M2} --architecture x86 -D target_i386_linux -D NO_TERNARY_SUPPORT -D ONE_PASS_GENERATOR -D SMALL_HEAP -D NO_SUPPORT_TENTATIVE_DECLS -I ${M2LIB} --expand-includes --debug ${PNUT}/pnut.c -o ${BUILD}/pnut.M1

${BLOOD} -f ${BUILD}/pnut.M1 --little-endian --entry _start -o ${BUILD}/pnut-footer.M1

${M1} -f ${M2LIB}/x86/x86_defs.M1 -f ${M2LIB}/x86/libc-full.M1 -f ${BUILD}/pnut.M1 -f ${BUILD}/pnut-footer.M1 --architecture x86 --little-endian -o ${BUILD}/pnut.hex2

${HEX2} --architecture x86 --little-endian --file ${M2LIB}/x86/ELF-x86-debug.hex2 --file ${BUILD}/pnut.hex2 --base-address 0x8048000 --output ${BUILD}/pnut-exe-by-M2-Planet

# Recompile pnut with itself
#${BUILD}/pnut ${PNUT}/pnut.c -Dtarget_i386_linux -D ONE_PASS_GENERATOR -o ${BUILD}/pnut-exe-by-pnut-exe

# Build pnut-exe which can be used to build tinycc
# (Modified from pnut/kit/setup-rootfs)
${BUILD}/pnut-exe-by-M2-Planet ${PNUT}/pnut.c \
  -Dtarget_i386_linux \
  -DONE_PASS_GENERATOR \
  -DSUPPORT_EMULATED_INT64 \
  -DUNDEFINED_LABELS_ARE_RUNTIME_ERRORS \
  -DENABLE_PNUT_INLINE_INTERRUPT \
  -DNO_BUILTIN_LIBC \
  -o ${BUILD}/pnut-exe-0

${BUILD}/pnut-exe-0 ${PNUT}/pnut.c \
  -Dtarget_i386_linux \
  -DONE_PASS_GENERATOR \
  -DSUPPORT_EMULATED_INT64 \
  -DUNDEFINED_LABELS_ARE_RUNTIME_ERRORS \
  -DENABLE_PNUT_INLINE_INTERRUPT \
  -DNO_BUILTIN_LIBC \
  -rt ${PNUT}/arith64.c \
  -I ${PNUT}/portable_libc/include/ \
  ${PNUT}/portable_libc/libc.c \
  -o ${BUILD}/pnut-exe

${BUILD}/pnut-exe ${PNUT}/pnut.c \
  -Dtarget_i386_linux \
  -DONE_PASS_GENERATOR \
  -DSUPPORT_EMULATED_INT64 \
  -DUNDEFINED_LABELS_ARE_RUNTIME_ERRORS \
  -DENABLE_PNUT_INLINE_INTERRUPT \
  -DNO_BUILTIN_LIBC \
  -rt ${PNUT}/arith64.c \
  -I ${PNUT}/portable_libc/include/ \
  ${PNUT}/portable_libc/libc.c \
  -o ${BUILD}/pnut-exe-self



echo "############### Building bintools ###############"

# Code below is mainly modified from pnut/kit/bootstrap.sh

# (1) pnut compiles positional files last-to-first (-rt is compiled first).
# (2) Only one -I is accepted by pnut, and the path must end with '/'

# build bintools

${BUILD}/pnut-exe -I ${PNUT}/portable_libc/include/ -rt ${PNUT}/arith64.c \
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
# [tcc.h] PNUT_CC NORETURN, ALIGNED(x) = [SPACE] (no __attribute__）
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
  -D TCC_TARGET_I386=1 \
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
  -rt pnut/arith64.c \
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
${CC} -ar -cr ${LIBPATH}/tcc/libtcc1.a ${LIBPATH}/libtcc1.o

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
	-D TCC_TARGET_I386=1 \
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
${CC} -ar -cr ${LIBPATH}/tcc/libtcc1.a ${LIBPATH}/libtcc1.o

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
	-D TCC_TARGET_I386=1 \
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
${CC} -ar -cr ${LIBPATH}/tcc/libtcc1.a ${LIBPATH}/libtcc1.o

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
	-D TCC_TARGET_I386=1 \
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
${CC} -ar -cr ${LIBPATH}/tcc/libtcc1.a ${LIBPATH}/libtcc1.o

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
	-D TCC_TARGET_I386=1 \
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
