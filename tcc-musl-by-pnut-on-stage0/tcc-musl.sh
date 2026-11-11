#!/build/kaem --file
#
# Build musl and a musl linked tcc with the bootstrapped tcc-boot3.
# Run by tcc-by-pnut-on-stage0-x86.sh as its last line; the shebang makes the
# kernel hand this file to kaem, which is why it has to be executable.
#
# kaem has no loops and passes at most about 500 arguments to a command, so the
# per-file work is driven by two generated files and one small program:
#   * /musl-1.2.5/tcc-files  is the list of musl sources to build,
#   * /musl-1.2.5/tcc-cflags carries the compiler flags, because kaem does not
#     split a ${variable} into several arguments (tcc expands @file itself),
#   * /musl-1.2.5/tcc-bootstrap/tcbuild.c is compiled here by tcc-boot3 and
#     reads that list, runs the compiler once per file, and finally hands every
#     object to a single "tcc -ar -cr" command.
#
# Two musl builds are needed because the boot libc that tcc-boot3 itself runs on
# understands only a few floating point literals: pass 1 can build everything
# except musl's maths, which is enough to link tcc-musl.  tcc-musl links the
# complete libtcc1.a, so its own constant folding is correct, and pass 2 then
# builds all of musl with it.  Finally tcc-musl rebuilds itself on that musl.

echo "##### musl + tcc-musl #####"

MUSL=/musl-1.2.5
LIBDIR=/usr/lib/musl
TCCSUB=/usr/lib/musl/tcc
WORK=/tccbuild
BOOT=/build/tcc-boot3
NEWTCC=/usr/bin/tcc-musl
FILES=${MUSL}/tcc-files

/build/bintools mkdir -p ${TCCSUB}
/build/bintools mkdir -p /usr/bin
/build/bintools mkdir -p ${WORK}
/build/bintools mkdir -p /build/boot2-lib/tcc

# ---------------------------------------------------------------------------
# the build driver, compiled by the boot tcc against the boot libc
# ---------------------------------------------------------------------------
echo "##### building the build driver #####"
cd /
${BOOT} -I pnut/portable_libc/include -o ${WORK}/tcbuild ${MUSL}/tcc-bootstrap/tcbuild.c

# ---------------------------------------------------------------------------
# tcc's runtime library: the complete 64 bit helpers, not the boot chain's stubs
# ---------------------------------------------------------------------------
cd ${MUSL}/tcc-bootstrap
${BOOT} -c tcc_libgcc.c -o ${WORK}/libtcc1.o
${BOOT} -ar -cr ${TCCSUB}/libtcc1.a ${WORK}/libtcc1.o

# ---------------------------------------------------------------------------
# pass 1: musl with tcc-boot3 (musl's maths cannot be built by this libc)
# ---------------------------------------------------------------------------
echo "##### pass 1: musl with tcc-boot3 #####"
cd /
${WORK}/tcbuild c ${BOOT} ${MUSL}/tcc-cflags ${MUSL} ${WORK}/p1 ${FILES}
${WORK}/tcbuild a ${BOOT} - ${MUSL} ${WORK}/p1 ${FILES} ${LIBDIR}/libc.a
/build/bintools cp ${WORK}/p1/crt/crt1.o ${LIBDIR}/crt1.o
/build/bintools cp ${WORK}/p1/crt/i386/crti.o ${LIBDIR}/crti.o
/build/bintools cp ${WORK}/p1/crt/i386/crtn.o ${LIBDIR}/crtn.o

# the boot tcc looks for its crt and libraries in build/boot2-lib
/build/bintools cp ${LIBDIR}/libc.a /build/boot2-lib/libc.a
/build/bintools cp ${TCCSUB}/libtcc1.a /build/boot2-lib/tcc/libtcc1.a
/build/bintools cp ${LIBDIR}/crt1.o /build/boot2-lib/crt1.o
/build/bintools cp ${LIBDIR}/crti.o /build/boot2-lib/crti.o
/build/bintools cp ${LIBDIR}/crtn.o /build/boot2-lib/crtn.o

# ---------------------------------------------------------------------------
# tcc-musl: built by the boot tcc, linked against the pass 1 musl
# ---------------------------------------------------------------------------
echo "##### building tcc-musl #####"
cd /
${BOOT} -static -o ${NEWTCC} \
	-D TCC_TARGET_I386=1 \
	-D CONFIG_TCCDIR=\"/usr/lib/musl/tcc\" \
	-D CONFIG_TCC_CRTPREFIX=\"/usr/lib/musl\" \
	-D CONFIG_TCC_ELFINTERP=\"/lib/ld-musl-i386.so.1\" \
	-D CONFIG_TCC_LIBPATHS=\"/usr/lib/musl:/usr/lib/musl/tcc\" \
	-D CONFIG_TCC_SYSINCLUDEPATHS=\"/musl-1.2.5/arch/i386:/musl-1.2.5/arch/generic:/musl-1.2.5/obj/include:/musl-1.2.5/include\" \
	-D TCC_LIBGCC=\"/usr/lib/musl/libc.a\" \
	-D CONFIG_TCC_STATIC=1 \
	-D CONFIG_USE_LIBGCC=1 \
	-D TCC_VERSION=\"0.9.27\" \
	-D ONE_SOURCE=1 \
	-D HAVE_LONG_LONG=1 \
	-D HAVE_FLOAT=1 \
	-D HAVE_BITFIELD=1 \
	-D __SIZEOF_LONG_LONG__=8 \
	-nostdinc -I/musl-1.2.5/arch/i386 -I/musl-1.2.5/arch/generic -I/musl-1.2.5/obj/include -I/musl-1.2.5/include \
	-L/build/boot2-lib \
	/build/tcc-0.9.27/tcc.c

# ---------------------------------------------------------------------------
# pass 2: all of musl, built by tcc-musl
# ---------------------------------------------------------------------------
echo "##### pass 2: musl with tcc-musl #####"
cd /
${WORK}/tcbuild c ${NEWTCC} ${MUSL}/tcc-cflags ${MUSL} ${WORK}/p2 ${FILES}
${WORK}/tcbuild a ${NEWTCC} - ${MUSL} ${WORK}/p2 ${FILES} ${LIBDIR}/libc.a
/build/bintools cp ${WORK}/p2/crt/crt1.o ${LIBDIR}/crt1.o
/build/bintools cp ${WORK}/p2/crt/i386/crti.o ${LIBDIR}/crti.o
/build/bintools cp ${WORK}/p2/crt/i386/crtn.o ${LIBDIR}/crtn.o

# ---------------------------------------------------------------------------
# rebuild tcc-musl with tcc-musl on the complete musl
# ---------------------------------------------------------------------------
echo "##### rebuilding tcc-musl with itself #####"
cd /
if ${NEWTCC} -static -o ${WORK}/tcc-musl.new \
	-D TCC_TARGET_I386=1 \
	-D CONFIG_TCCDIR=\"/usr/lib/musl/tcc\" \
	-D CONFIG_TCC_CRTPREFIX=\"/usr/lib/musl\" \
	-D CONFIG_TCC_ELFINTERP=\"/lib/ld-musl-i386.so.1\" \
	-D CONFIG_TCC_LIBPATHS=\"/usr/lib/musl:/usr/lib/musl/tcc\" \
	-D CONFIG_TCC_SYSINCLUDEPATHS=\"/musl-1.2.5/arch/i386:/musl-1.2.5/arch/generic:/musl-1.2.5/obj/include:/musl-1.2.5/include\" \
	-D TCC_LIBGCC=\"/usr/lib/musl/libc.a\" \
	-D CONFIG_TCC_STATIC=1 \
	-D CONFIG_USE_LIBGCC=1 \
	-D TCC_VERSION=\"0.9.27\" \
	-D ONE_SOURCE=1 \
	-D HAVE_LONG_LONG=1 \
	-D HAVE_FLOAT=1 \
	-D HAVE_BITFIELD=1 \
	-D __SIZEOF_LONG_LONG__=8 \
	-nostdinc -I/musl-1.2.5/arch/i386 -I/musl-1.2.5/arch/generic -I/musl-1.2.5/obj/include -I/musl-1.2.5/include \
	/build/tcc-0.9.27/tcc.c
/build/bintools cp ${WORK}/tcc-musl.new ${NEWTCC}
fi

echo "##### musl and tcc-musl are built #####"
