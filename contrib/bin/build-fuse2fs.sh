#!/bin/sh
# Static fuse2fs (ext2/3/4 through FUSE) for the Station: the stock kernel has no ext4 and an
# ext4 module cannot be built safely for it (docs/recipes/usb-host.md), Entware has no fuse2fs.
# Requirements (Ubuntu/Debian): gcc-aarch64-linux-gnu make curl xz-utils
#   ./build-fuse2fs.sh        -> ./fuse2fs (aarch64, static, ~1.3 MB)
set -e
W=${WORK:-$(pwd)/fuse2fs-build}
OUT=$(pwd)/fuse2fs
mkdir -p "$W" && cd "$W"
[ -f fuse-2.9.9.tar.gz ] || curl -fsSLO https://github.com/libfuse/libfuse/releases/download/fuse-2.9.9/fuse-2.9.9.tar.gz
[ -f e2fsprogs-1.47.1.tar.xz ] || curl -fsSLO https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v1.47.1/e2fsprogs-1.47.1.tar.xz
echo "d0e69d5d608cc22ff4843791ad097f554dd32540ddc9bed7638cc6fea7c1b4b5  fuse-2.9.9.tar.gz
5a33dc047fd47284bca4bb10c13cfe7896377ae3d01cb81a05d406025d99e0d1  e2fsprogs-1.47.1.tar.xz" | sha256sum -c

rm -rf fuse-2.9.9 e2fsprogs-1.47.1 sysroot
tar xzf fuse-2.9.9.tar.gz
# fuse 2.9.9 defines __u64 & co. itself, which clashes with current kernel headers
sed -i 's|^#define __u64 uint64_t$|#include <linux/types.h>|; /^#define __[us]\(64\|32\|16\) u\{0,1\}int\(64\|32\|16\)_t$/d' fuse-2.9.9/include/fuse_kernel.h
(cd fuse-2.9.9 && ./configure --host=aarch64-linux-gnu --prefix="$W/sysroot" --enable-static --disable-shared \
	--disable-util --disable-example --disable-mtab >/dev/null && make -j"$(nproc)" >/dev/null && make install >/dev/null)

tar xJf e2fsprogs-1.47.1.tar.xz
cd e2fsprogs-1.47.1
PKG_CONFIG_LIBDIR="$W/sysroot/lib/pkgconfig" CFLAGS="-O2 -I$W/sysroot/include" LDFLAGS="-static -L$W/sysroot/lib" \
	./configure --host=aarch64-linux-gnu --disable-nls --enable-fuse2fs --without-libarchive --disable-uuidd --disable-fsck >/dev/null
make -j"$(nproc)" libs >/dev/null
make -C misc fuse2fs CFLAGS="-O2 -I$W/sysroot/include -D_FILE_OFFSET_BITS=64" >/dev/null
aarch64-linux-gnu-strip -o "$OUT" misc/fuse2fs
ls -la "$OUT"
