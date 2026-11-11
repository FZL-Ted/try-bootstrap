
set -eu

cd $(dirname ${BASH_SOURCE[0]})
echo "Current working directory: " $(pwd)

############################################################
#                    Command line options                  #
############################################################

# The stage0-posix tree spells the same architecture in more than one way, so
# each supported architecture has these spellings:
#   ARCH_LOWERCASE  lowercase: ./kaem.<arch>, tcc-by-pnut-on-stage0-<arch>.sh
#   ARCH_DIR        as the stage0-posix target directory is named (AMD64, not amd64)
#   SEED_DIR        as bootstrap-seeds/POSIX/<seed_dir> is named
usage() {
  cat <<EOF
Usage: $(basename "$0") [--arch <arch>]

Supported architectures: x86, amd64

  x86    32-bit x86 (i386 target)
  amd64  64-bit x86-64 (x86_64 target)

Options:
  --arch <arch>  Architecture to bootstrap (default: x86).
  --help, -h     Print this help message and exit.

Each architecture selects its bootstrap script and its stage0-posix entry:
  x86    tcc-by-pnut-on-stage0-x86.sh
         ./stage0/bootstrap-seeds/POSIX/x86/kaem-optional-seed   ./stage0/kaem.x86
  amd64  tcc-by-pnut-on-stage0-amd64.sh
         ./stage0/bootstrap-seeds/POSIX/AMD64/kaem-optional-seed ./stage0/kaem.amd64
EOF
}

TARGET_ARCH=x86

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --arch)
      if [ $# -lt 2 ]; then
        echo "Error: --arch requires an argument (x86 or amd64)." >&2
        usage >&2
        exit 1
      fi
      TARGET_ARCH=$2
      shift 2
      ;;
    --arch=*)
      TARGET_ARCH=${1#--arch=}
      shift
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$TARGET_ARCH" in
  x86)
    ARCH_LOWERCASE=x86
    ARCH_DIR=x86
    SEED_DIR=x86
    ;;
  amd64)
    ARCH_LOWERCASE=amd64
    ARCH_DIR=AMD64
    SEED_DIR=AMD64
    ;;
  *)
    echo "Error: unsupported architecture: $TARGET_ARCH (supported: x86, amd64)" >&2
    exit 1
    ;;
esac

echo "Target architecture: ${ARCH_LOWERCASE} (stage0-posix ${ARCH_DIR})"

############################################################
#                  Prepare stage0-posix                    #
############################################################

ARCH1=(x86 AMD64 riscv32 riscv64 AArch64)
ARCH2=(x86 amd64 riscv32 riscv64 aarch64)

# Stage0-posix 643598 (2026-07-05) use M2-Planet bd2fe4 (2025-08-17) tag:rel-1.13.1
if [ ! -e stage0-posix ]; then
  echo "Downloading stage0-posix ..."
  git clone --depth 1 https://github.com/oriansj/stage0-posix.git
  cd stage0-posix
  # We do not need {M2-*,mescc-*}/M2libc, so no --recursive.
  git submodule update --init
  cd ..
fi
cd stage0-posix


# Building pnut needs M2-Planet's commit 54e8f82b (multiplication in constant expr).
# Bootstrapping using M2-Planet 34fbd5c2 (latest) needs new versions of other submodules.
# So we just update all the submodules to the latest versions.
cdgitchk() {
  __prevdir=$(pwd) && cd ${1} && git checkout ${2} && cd ${__prevdir}
}
cdgitchk M2-Planet      master
cdgitchk M2libc         main
cdgitchk M2-Mesoplanet  main
cdgitchk x86      master
cdgitchk AMD64    master
cdgitchk riscv32  master
cdgitchk riscv64  master
cdgitchk AArch64  master

# Remove sha256sum check
for archi in ${ARCH1[@]}; do
  sed -i.bak '/sha256sum/ s/^/# /' ${archi}/kaem.run
# sed -i '/sha256sum/ s/^# //' x86/kaem.run
done
# Get new <arch>.answers:
# sha256sum x86/bin/* > x86.answers.current

# New version of AArch64 have bugs, apply patches.
# cc_c-aarch64-ret-fix-precedence.patch has been merged.
cd AArch64
PATCH=../../patches/cc_aarch64-require_global_token-preserve-x0.patch
if git apply --check "$PATCH" 2>/dev/null; then
  git apply "$PATCH"
fi
cd ..

# M2-Planet master miscompiles ++/-- on global/static variables: it loads the
# value instead of leaving the address in place, so "++global" treats the value
# as a pointer. Building pnut needs "++string_pool_alloc" in pnut.c, which then
# segfaults (or the generated pnut-exe-by-M2-Planet does).
cd M2-Planet
PATCH=../../patches/cc_core-global-inc-dec-address.patch
if git apply --check "$PATCH" 2>/dev/null; then
  git apply "$PATCH"
fi
cd ..

# If you want to test stage0-posix:
if [ 0 == 1 ]; then
  arch_idx=0
  qemu-i386 ./bootstrap-seeds/POSIX/${ARCH1[arch_idx]}/kaem-optional-seed ./kaem.${ARCH2[arch_idx]}
fi

# Edit stage0-posix
STAGE0_PATH=.
# ARCH_DIR and ARCH_LOWERCASE are derived from --arch above (default: x86).

REPLACE_DIR_IN_KAEM=${REPLACE_DIR_IN_KAEM:-1}
if [ $REPLACE_DIR_IN_KAEM == "1" ] && ! grep -q "stage0" ${STAGE0_PATH}/kaem.${ARCH_LOWERCASE}; then
  # ./ => ./stage0/
  sed -i.bak1 's/\.\//\.\/stage0\//g' ${STAGE0_PATH}/kaem.${ARCH_LOWERCASE}
  sed -i.bak1 's/\.\//\.\/stage0\//g' ${STAGE0_PATH}/${ARCH_DIR}/mescc-tools-seed-kaem.kaem
  sed -i.bak1 's/\.\//\.\/stage0\//g' ${STAGE0_PATH}/${ARCH_DIR}/mescc-tools-mini-kaem.kaem
  sed -i.bak1 's/\.\//\.\/stage0\//g' ${STAGE0_PATH}/${ARCH_DIR}/mescc-tools-full-kaem.kaem
  # ./stage0/${ARCH_DIR}/artifact/ => ./build/
  sed -i.bak1 "s/\.\/stage0\/${ARCH_DIR}\/artifact\//\.\/build\//g" ${STAGE0_PATH}/kaem.${ARCH_LOWERCASE}
  sed -i.bak1 "s/\.\/stage0\/${ARCH_DIR}\/artifact\//\.\/build\//g" ${STAGE0_PATH}/${ARCH_DIR}/mescc-tools-seed-kaem.kaem
  sed -i.bak1 "s/\.\/stage0\/${ARCH_DIR}\/artifact\//\.\/build\//g" ${STAGE0_PATH}/${ARCH_DIR}/mescc-tools-mini-kaem.kaem
  sed -i.bak1 "s/\.\/stage0\/${ARCH_DIR}\/artifact\//\.\/build\//g" ${STAGE0_PATH}/${ARCH_DIR}/mescc-tools-full-kaem.kaem
  # ./stage0/${ARCH_DIR}/bin/ => ./build/
  sed -i.bak1 "s/\.\/stage0\/${ARCH_DIR}\/bin\//\.\/build\//g" ${STAGE0_PATH}/kaem.${ARCH_LOWERCASE}
  sed -i.bak1 "s/\.\/stage0\/${ARCH_DIR}\/bin\//\.\/build\//g" ${STAGE0_PATH}/${ARCH_DIR}/mescc-tools-seed-kaem.kaem
  sed -i.bak1 "s/\.\/stage0\/${ARCH_DIR}\/bin\//\.\/build\//g" ${STAGE0_PATH}/${ARCH_DIR}/mescc-tools-mini-kaem.kaem
  sed -i.bak1 "s/\.\/stage0\/${ARCH_DIR}\/bin\//\.\/build\//g" ${STAGE0_PATH}/${ARCH_DIR}/mescc-tools-full-kaem.kaem
fi

# If you want to remove mesoplanet build in mescc-tools-full-kaem.kaem
NO_MESOPLANET_IN_KAEM=${NO_MESOPLANET_IN_KAEM:-0}
if [ $NO_MESOPLANET_IN_KAEM == "1" ]; then
  file=$STAGE0_PATH/$ARCH_DIR/mescc-tools-full-kaem.kaem
  begin_line=$(grep -n 'Phase-12' "$file" | cut -d: -f1 || exit 1)
  end_line=$(grep -n 'Phase-13' "$file" | cut -d: -f1 || exit 2)
  end_line=$(( end_line - 1 ))
  echo "del " "$file " "$begin_line" "~" "$end_line"
  sed -i "${begin_line},${end_line}d" "$file"
fi

cd ..

############################################################
#                     Prepare pnut/tcc                     #
############################################################

# pnut has tcc's tarball.
if [[ ! -e pnut ]]; then
  echo "Downloading pnut ..."
  # Add --recursive if you need C4
  git clone --depth 1 --recursive https://github.com/udem-dlteam/pnut.git
  #git checkout abc34a5207b1373d0a4e3dcb3d3d6df6e22ae23d
fi

# M2-Planet's int is register-sized, so it is 8 bytes when M2-Planet targets
# amd64, while pnut's emulated 64-bit literals (SUPPORT_64_BIT_LITERALS, enabled
# for the x86_64 target) are two 32-bit words that must wrap at 32 bits. The
# patch also works around M2-Planet parsing -x[i] as (-x)[i]. It only changes
# the pnut binaries: the compilers they build are unaffected.
cd pnut
PATCH=../patches/pnut-m2-amd64-int32-u64-literals.patch
if git apply --check "$PATCH" 2>/dev/null; then
  git apply "$PATCH"
elif ! git apply --check --reverse "$PATCH" 2>/dev/null; then
  # Neither applies nor is already applied: a newer pnut changed the context.
  echo "Warning: $PATCH does not apply to this pnut checkout." >&2
  echo "         The amd64 bootstrap needs it; the x86 one does not." >&2
fi
cd ..


############################################################
#                     Prepare rootfs                       #
############################################################


rm -rf rootfs
mkdir -p rootfs/stage0/${ARCH_DIR}
mkdir -p rootfs/pnut
mkdir -p rootfs/{build,bin}

echo "=== $(pwd)"

cp -r ./stage0-posix/* ./rootfs/stage0/

cp tcc-by-pnut-on-stage0-${ARCH_LOWERCASE}.sh rootfs/stage0/${ARCH_DIR}/kaem.run

cp -r ./pnut/* ./rootfs/pnut/

# pnut's bintools sources live in kit/bintools/ and are flattened into
# kit/bintools.c by pnut's own utils/process-includes.sh now.
( cd pnut && ./utils/process-includes.sh kit/bintools/bintools-base.c ) > rootfs/pnut/kit/bintools.c


############################################################
#                      Run in bwrap                        #
############################################################


RUN_IN_BWRAP=1
if [ $RUN_IN_BWRAP == "1" ]; then
  bwrap --bind ./rootfs / \
    --proc /proc \
    --dev /dev \
    ./stage0/bootstrap-seeds/POSIX/${SEED_DIR}/kaem-optional-seed ./stage0/kaem.${ARCH_LOWERCASE}
fi
