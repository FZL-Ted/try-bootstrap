# For reference, do not run.
exit

# Tarball:
# binutils-2.44.tar.gz
# gcc-4.6.4.1.tar.gz
# gcc-10.4.0.tar.gz
# gmp-6.2.1.tar.xz
# make-4.4.tar.gz
# mpc-1.2.1.tar.gz
# mpfr-4.1.0.tar.xz
# musl-1.2.6.zip
# zlib-1.3.2.tar.gz





# xcc
git clone --depth 1 https://github.com/tyfkda/xcc.git

# GCC 4.6.4 fork for bootstrapping, with added RISC-V support.
git clone --depth 1 https://codeberg.org/ekaitz-zarraga/gcc.git
# Actually use a tarball from this codeberg link. gcc-4.6.4.1.tar.gz

# musl-1.2.6
https://github.com/kraj/musl/tree/v1.2.6

GMP=gmp-6.2.1
MPFR=mpfr-4.1.0
MPC=mpc-1.2.1
wget ftp://gcc.gnu.org/pub/gcc/infrastructure/$MPFR.tar.bz2 || exit 1
wget ftp://gcc.gnu.org/pub/gcc/infrastructure/$GMP.tar.bz2 || exit 1
wget ftp://gcc.gnu.org/pub/gcc/infrastructure/$MPC.tar.gz || exit 1

# binutils: --disable-{gold,gprofng,gdb} to make it compilable with c (no c++).
# 2.44 may be the last version can be built without c++ compiler.
# 2.44 could be used for LFS
wget https://ftp.gnu.org/gnu/binutils/binutils-2.44.tar.gz

# gcc-10.4.0: nixpkgs/.../minimal-bootstrap says it is the last version built with gcc-4.6
https://ftp.gnu.org/gnu/gcc/gcc-10.4.0/gcc-10.4.0.tar.gz

# gnu make (latest version) it's said that it can be built without make .
https://ftp.gnu.org/gnu/make/make-4.4.tar.gz

# toybox
https://github.com/landley/toybox.git
