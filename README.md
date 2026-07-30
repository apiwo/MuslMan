# MuslMan

Full proprietary NVIDIA driver acceleration — kernel modules, OpenGL/EGL,
Vulkan, CUDA, X11 **and** Wayland — on any musl libc Linux distro (Alpine,
Void musl, Gentoo's musl profile, Chimera Linux, Adélie, or anything else
using musl, detected generically rather than from a distro allowlist).

```
git clone https://github.com/apiwo/MuslMan
cd MuslMan
sudo ./muslman doctor
sudo ./muslman install
```

## Why this needs to exist

NVIDIA's proprietary Linux driver ships two very different things bundled
into one `.run` installer:

- **Kernel modules** (`nvidia`, `nvidia-drm`, `nvidia-modeset`,
  `nvidia-uvm`, ...) — plain C, built freestanding against your running
  kernel's headers. libc flavor of the host doesn't matter here; musl
  builds these exactly as any other distro does.
- **Userspace libraries** (`libGLX_nvidia.so`, `libEGL_nvidia.so`,
  `libnvidia-glcore.so`, `libcuda.so`, `nvidia-smi`, the Xorg
  `nvidia_drv.so`, ...) — precompiled **against glibc** by NVIDIA. These
  won't run on a pure musl system at all: no `glibc`, no dynamic linker
  they can use.

That second part is the actual hard problem, and it's what most of
MuslMan's logic is about.

## Architecture

1. **Container-only compiling.** No compiler, linker, or `patchelf` ever
   runs against your host filesystem. MuslMan bootstraps a small cached
   Alpine musl rootfs (`~/.cache/muslman/sandbox-rootfs`) and runs every
   build step inside a [bubblewrap](https://github.com/containers/bubblewrap)
   (`bwrap`) sandbox with its own mount/pid/ipc/uts/cgroup namespaces.
   Actual compilation additionally runs with `--unshare-net`, so the
   sandbox has **no network access at all** while a compiler or patchelf
   is running — verified in this repo's own development by confirming a
   `wget` inside that stage fails to even resolve DNS. Docker/Podman
   would work too, but bubblewrap needs no daemon and installs nothing
   new on your system, which is why MuslMan uses it. Kernel headers are
   the one thing that must come from the real host (they have to match
   your exact running kernel); they're bind-mounted into the sandbox
   **read-only**.

   Why an Alpine rootfs specifically, regardless of what distro you're
   installing *onto*: musl doesn't do symbol versioning, so a small
   userspace library built against one musl version runs fine against
   another musl version on a different distro. Alpine's minirootfs is
   small, official, and easy to bootstrap reproducibly. If you want to
   build against your *exact* target distro's musl instead, pass
   `--rootfs-tarball /path/to/your-rootfs.tar.gz`.

2. **Kernel modules**: extracted from the `.run` payload (preferring
   `kernel-open/`, NVIDIA's open-source GPU kernel modules used by
   default for Turing-generation and newer GPUs, falling back to the
   legacy closed `kernel/` tree for older cards), built in the sandbox
   against your host's `/lib/modules/$(uname -r)/build`, then copied to
   `/lib/modules/$(uname -r)/extra/muslman/` and registered with `depmod`.

3. **glibc-compat runtime, not a symbol shim.** Rather than a minimal
   shim like `gcompat` (which doesn't cover nearly enough of the glibc
   symbol surface for something as large as the GL/EGL/Vulkan/CUDA
   stack), MuslMan vendors a real glibc build:
   [`sgerrand/alpine-pkg-glibc`](https://github.com/sgerrand/alpine-pkg-glibc),
   an upstream Debian/Ubuntu-built glibc repackaged specifically so
   glibc binaries can run unmodified on musl/Alpine systems. It's
   extracted (never installed system-wide) to `/opt/muslman/glibc-compat`.

4. **`patchelf` pass** (inside the sandbox, offline): every NVIDIA
   userspace `.so`/binary that actually has a glibc `PT_INTERP` gets its
   interpreter and rpath repointed at that vendored glibc-compat tree.
   Files patchelf can't make sense of are skipped, not fatal.

5. **Wayland/EGL/GBM built fresh, not patched.** `NVIDIA/egl-wayland` and
   `NVIDIA/egl-gbm` are small, permissively-licensed, open-source glue
   libraries NVIDIA publishes on GitHub. MuslMan builds them natively for
   musl inside the sandbox with meson/ninja — no glibc dependency at all
   on the Wayland/DRM/KMS path (Sway, wlroots compositors, etc.).

6. **Everything installs under `/opt/muslman/`**, never overwriting
   system library directories. The only host files MuslMan writes outside
   that prefix are small, well-known integration points, every one of
   them tracked (with a backup of anything it overwrote) in
   `/var/lib/muslman/manifest`:

   | File | Purpose |
   |---|---|
   | `/etc/modprobe.d/muslman-nvidia.conf` | blacklist nouveau, `nvidia-drm modeset=1` |
   | `/etc/modules-load.d/muslman-nvidia.conf` (or OpenRC `/etc/conf.d/modules`, or `/etc/dinit.d/muslman-nvidia` on dinit) | autoload the modules at boot |
   | `/etc/X11/xorg.conf.d/20-muslman-nvidia.conf` | X11/XWayland GLX driver path |
   | `/usr/share/glvnd/egl_vendor.d/10_nvidia.json` | EGL vendor (libglvnd) |
   | `/etc/vulkan/icd.d/nvidia_icd.json` | Vulkan ICD |
   | `/etc/udev/rules.d/70-muslman-nvidia.rules` | creates `/dev/nvidia*` on module load |
   | `/etc/ld-musl-<arch>.path` | adds `/opt/muslman/nvidia/lib` to musl's library search path |

## Commands

```
sudo ./muslman doctor       # check prerequisites, prints fixes, installs nothing
sudo ./muslman install      # full build + install
sudo ./muslman status       # module/device-node/nvidia-smi state
sudo ./muslman uninstall    # reverses everything, restores backed-up files
sudo ./muslman build        # run the sandboxed build steps only, skip host install
```

Useful options: `--driver-version X.Y.Z`, `--driver-file /path/to.run`,
`--rootfs-tarball /path/to/alt-rootfs.tar.gz`, `-y`/`--yes`. Full list in
`./muslman help`.

## Requirements

- A musl libc system (`muslman` refuses to run `install`/`uninstall` on
  anything else — this is a deliberate safety guard, not just a check).
- x86_64 (NVIDIA doesn't ship consumer GeForce/RTX Linux drivers for
  other architectures).
- `bubblewrap`, `curl`, `tar`, and the standard `kmod` tools
  (`modprobe`/`depmod`/`lsmod`) on the **host**.
- Your kernel's headers/build tree present and matching `uname -r`
  exactly (e.g. `/lib/modules/$(uname -r)/build`). `muslman doctor` checks
  for this and prints the right install command for your package manager
  — it never installs anything on the host itself.
- Root, and a network connection (only needed for `doctor`'s advice being
  followed and for the download/build steps — actual compiling is
  network-isolated regardless).

## Honest status

This was engineered from documented, real-world-precedented building
blocks — Alpine's own `alpine-pkg-glibc` compatibility package,
`patchelf`-based ABI bridging (the same technique the Nix and Steam
Runtime ecosystems use to run foreign-libc binaries), and NVIDIA's own
open-source `egl-wayland`/`egl-gbm` projects. The bubblewrap sandbox
mechanics, the Alpine rootfs bootstrap, and the offline
compile/network-isolation boundary were all exercised for real during
development (see commit history). **The end-to-end result has not been
tested against real musl+NVIDIA hardware** — this development machine is
glibc and has no spare NVIDIA musl box to validate against. Before
relying on this:

- Test on a machine you can afford to have not boot cleanly the first
  time, or make sure you have a fallback (a `nomodeset` / nouveau boot
  option in your bootloader, or a spare TTY / SSH access that doesn't
  depend on the GPU driver working).
- If something goes wrong, `sudo ./muslman uninstall` reverses every file
  MuslMan wrote and restores anything it backed up.
- If your package manager or init system isn't yet handled well by
  `lib/distro.sh`, `muslman doctor` will tell you what it couldn't detect
  rather than silently guessing — please open an issue/PR with what your
  distro needs.

## License

MIT — see [LICENSE](LICENSE).
