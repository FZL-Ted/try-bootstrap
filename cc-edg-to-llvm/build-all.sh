#!/usr/bin/env bash
#
# Run the whole "reference host + musl" bootstrap chain:
#
#     refhost-musl.sh  ->  refhost-edg5.1.sh  ->  refhost-edg7.0.sh
#
# All environment variables understood by the stages are inherited, most
# importantly HOSTCC (gcc or clang) and ROOTFS:
#
#     ./build-all.sh
#         host gcc,  rootfs-hostgcc
#
#     HOSTCC=clang ROOTFS=rootfs-hostclang ./build-all.sh
#         host clang, rootfs-hostclang
#
# `HOSTCC=clang ROOTFS=rootfs-hostclang ./*.sh` also works: the shell expands
# the glob in sorted order, so this script is the one that runs and the other
# script names are ignored as arguments.
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)

echo "==> bootstrap root: $ROOT"
echo "==> HOSTCC=${HOSTCC:-gcc (from PATH)}  ROOTFS=${ROOTFS:-rootfs-hostgcc}"
echo

"$ROOT/refhost-musl.sh"
echo
"$ROOT/refhost-edg5.1.sh"
echo
"$ROOT/refhost-edg7.0.sh"
