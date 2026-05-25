#!/bin/bash
# Build the JetKVM rv1106 buildkit tarball from inside an Ubuntu container,
# tolerating Apple Silicon Rosetta's intermittent x86_64-translation
# segfaults in the Rockchip cross-toolchain.
#
# Why this exists:
#   The upstream build path (./build.sh lunch ...; ./build.sh) drives the
#   Rockchip BSP and is meant for an x86_64 Linux build host. On an Apple
#   Silicon Mac running the build inside Colima vz+Rosetta, the cross gcc
#   binary (`arm-rockchip830-linux-uclibcgnueabihf-gcc`) periodically
#   segfaults during cc1/as runs because Rosetta's translation of certain
#   gcc internal paths is non-deterministic. There's no single bad input;
#   the same .c file may crash on attempt 1 and succeed on attempt 2.
#
# What this script does:
#   1. Installs host deps inside the container.
#   2. Wraps the cross gcc/g++ binaries in /opt-installed toolchain so
#      that exit codes 4 (gcc's "internal compiler error" code that wraps
#      cc1 SIGSEGV), 137 (SIGKILL), and 139 (SIGSEGV) trigger up to 8
#      retries. PATH-based shadowing would not work because CMake records
#      absolute paths at configure time.
#   3. Builds only what `make_buildkit.sh` actually needs: media (rockit,
#      mpp, rga, etc.) and two sysdrv toolkits (zlib, openssl). The full
#      `./build.sh sysdrv` would also build u-boot, whose ARM assembly
#      consistently crashes the Rosetta-translated assembler.
#   4. Runs `./make_buildkit.sh` to emit `buildkit.tar.zst` at the repo
#      root.
#
# Usage (from a clone of this repo on macOS):
#   colima start --cpu 4 --memory 8 --vm-type=vz --vz-rosetta   # one-time
#   docker run --rm \
#       --platform linux/amd64 \
#       -v "$PWD:/repo" -w /repo \
#       mcr.microsoft.com/devcontainers/base:ubuntu-22.04 \
#       bash /repo/scripts/build-buildkit-rosetta.sh
#
# Output: /repo/buildkit.tar.zst (~58 MB). Extract to /opt/jetkvm-native-buildkit
# inside the kvm-app build container; see the matching script in the kvm fork.

set -euxo pipefail

cd /repo

export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null
apt-get install -y --no-install-recommends \
  build-essential autoconf autotools-dev device-tree-compiler gperf \
  g++-multilib gcc-multilib libnl-3-dev libdbus-1-dev libelf-dev libmpc-dev \
  dwarves bc openssl flex bison libssl-dev python3 python-is-python3 \
  texinfo kmod cmake \
  ca-certificates rsync file unzip perl make autoconf libtool zstd >/dev/null

RK_ARCH=arm-rockchip830-linux-uclibcgnueabihf
TOOLCHAIN_BIN=/repo/tools/linux/toolchain/${RK_ARCH}/bin
export PATH="${TOOLCHAIN_BIN}:$PATH"

# Install retry wrappers in-place on the cross gcc/g++. Renames real
# binary to .orig, replaces with shim that retries on Rosetta segfaults.
# In-place rather than PATH-shadowed because CMake-generated makefiles
# bake in absolute paths to the compiler at configure time.
for tool in gcc g++; do
  REAL="${TOOLCHAIN_BIN}/${RK_ARCH}-${tool}"
  if [ ! -f "${REAL}.orig" ]; then
    mv "${REAL}" "${REAL}.orig"
    cat > "${REAL}" <<EOF
#!/bin/bash
set -u
for attempt in 1 2 3 4 5 6 7 8; do
  "${REAL}.orig" "\$@"
  rc=\$?
  case \$rc in
    4|137|139) ;;
    *) exit \$rc ;;
  esac
  echo "rosetta-retry: ${tool} rc=\$rc attempt \$attempt; retrying..." >&2
  sleep 1
done
echo "rosetta-retry: ${tool} kept crashing 8x; giving up" >&2
exit \$rc
EOF
    chmod +x "${REAL}"
  fi
done
${RK_ARCH}-gcc --version | head -1

export RK_CHIP=rv1106 SYSDRV_CROSS=${RK_ARCH}

# Idempotency: if a previous run produced media/out, skip the media
# build (it's the slowest stage — ~10 min — and not worth re-running).
if [ ! -d /repo/media/out/lib ] || [ -z "$(ls -A /repo/media/out/lib 2>/dev/null)" ]; then
  echo "=== building media (rockit + mpp + rga + ...) ==="
  ./build.sh lunch BoardConfig_IPC/BoardConfig-EMMC-NONE-RV1106_JETKVM_V2.mk
  ./build.sh media
else
  echo "=== media/out already present; skipping media build ==="
fi

# Build the two toolkits make_buildkit.sh needs from sysdrv. Skipping the
# rest of sysdrv (u-boot, kernel) avoids the deterministic Rosetta crash
# in ARM assembly and is much faster.
for pkg in zlib openssl; do
  echo "=== building toolkit: $pkg ==="
  ( cd /repo/sysdrv/tools/board/toolkits/$pkg && \
    make -j"$(nproc)" CHIP=${RK_CHIP} SYSDRV_CROSS=${SYSDRV_CROSS} )
done

# Package everything into the buildkit tarball (zstd, long=31 dictionary).
echo "=== make_buildkit.sh ==="
cd /repo
./make_buildkit.sh

ls -la /repo/buildkit.tar.zst
echo "BUILD OK: buildkit.tar.zst ready at $(realpath /repo/buildkit.tar.zst)"
