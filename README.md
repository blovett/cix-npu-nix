# CIX SKY1 / Radxa Orion O6 NPU on NixOS

A Nix flake that packages the **ArmChina Zhouyi (aipu) NPU** stack for the
CIX SKY1 SoC (Radxa Orion O6) on **NixOS with a mainline kernel**:

- `aipu.ko` — the out-of-tree kernel module, built against the running
  kernel, with a compat patch for Linux 6.11 / 7.x.
- `cix-noe-umd` (`libnoe`) — the NOE user-mode driver, plus its Python
  bindings (`libnoe`, `NOE_Engine`).
- a topology smoke test and an end-to-end MobileNet-V2 inference demo.

Nothing is vendored. The driver source is pinned to upstream git commits
(`cixtech/cix_opensource__npu_driver`); the userspace `.deb` is
`fetchurl`-ed from Radxa's public `cd8180-bookworm` apt repo. See
`flake.lock` and `noe-umd.nix`.

Tested on a Radxa Orion O6, NixOS, `linuxPackages_latest` (kernel 7.2.0).

## Packages

`nix build .#<name>`:

| name | what |
|---|---|
| `aipu` (default) | **KMD 5.11.0** module — matches `cix-noe-umd` 2.0.2 / CixBuilder 6.1 |
| `aipu-6_0_1` | KMD 6.0.1 module — builds & probes, but its ioctl ABI has no matching released userspace |
| `cix-noe-umd` | C library `libnoe.so` + header + pkg-config |
| `libnoe` | `python312` CPython bindings |
| `noe-engine` | `python312` `NOE_Engine.EngineInfer` high-level wrapper |
| `noe-smoketest` | C `libnoe` → `/dev/aipu` topology probe |
| `noe-python` | `python312` with `libnoe` + `noe-engine` |
| `infer-mobilenet` | end-to-end MobileNet-V2 ImageNet inference on the NPU |

`nix develop` gives a C toolchain (for building `smoketest.c` against
`libnoe`) plus a `python3` carrying the NOE bindings, with
`PKG_CONFIG_PATH` / `LD_LIBRARY_PATH` already pointed at `cix-noe-umd`.

## Use it in a NixOS config

```nix
{
  inputs.cix-npu.url = "github:blovett/cix-npu-nix";
  inputs.cix-npu.inputs.nixpkgs.follows = "nixpkgs";

  # in your system modules:
  #   cix-npu.nixosModules.default
}
```

`nixosModules.default` (alias `nixosModules.aipu`) adds the KMD 5.11.0
build to `boot.extraModulePackages`, puts `aipu` in `boot.kernelModules`,
and installs `noe-smoketest`. The module autoloads on boot via the
`acpi:CIXH4000:` modalias; `boot.extraModulePackages` changes need a
reboot. The C library and Python env are dev-oriented — pull them in
separately with `nix build .#cix-noe-umd` / `nix shell .#noe-python`.

## Build and load the module directly

```
$ nix build .#aipu
$ sudo insmod result/lib/modules/$(uname -r)/extra/aipu.ko
$ ls -l /dev/aipu
```

`runtime-test.sh` loads the freshly built module, probes `CIXH4000:00`,
dumps `dmesg`, and unloads it again — handy after a kernel bump. (Run it
after a fresh boot: a failed probe can wedge the module, and this kernel
has no `MODULE_FORCE_UNLOAD`.)

### Topology probe

```
$ nix build .#noe-smoketest
$ ./result/bin/noe-smoketest
noe_init_context             -> 0
noe_get_target               -> 0
    NPU arch: X2_1204MP3
noe_get_partition_count      -> 0
    partitions: 1
    partition 0: 1 cluster(s)
      cluster 0: 3 core(s)
noe_deinit_context           -> 0
OK
```

This exercises userspace → `/dev/aipu` → `aipu.ko` end to end, with no
compiled model required.

### End-to-end inference demo

```
$ nix run .#infer-mobilenet          # aipu.ko must be loaded
image: …/ILSVRC2012_val_00002899.JPEG
  1. [ 61] boa constrictor …          (21.575)
  2. [ 62] rock python …              (21.575)
  ...
10 runs:  NPU compute 0.68 ms/inf   end-to-end forward() 1.98 ms/inf

$ nix run .#infer-mobilenet -- /path/to/your.jpg
```

A CixBuilder-compiled `mobilenet_v2.cix` and a sample ImageNet image are
fetched from the version-matched `ai_model_hub` (2025Q3) on ModelScope.
The path is: `.cix` graph → `NOE_Engine` → `libnoe` → `/dev/aipu` →
`aipu.ko` (KMD 5.11.0) → Zhouyi X2. `inference/infer_mobilenet.py` does
the ImageNet preprocessing with just PIL + numpy.

## Why two KMD versions

The NPU ioctl ABI (`struct aipu_cap`: `asid_base[32]` vs `[4]`, etc.) must
match the userspace. The set that agrees today:

- **CixBuilder 6.1.3407 + cix-noe-umd 2.0.2 + KMD 5.11.0** — the 2025Q3
  NOE SDK. KMD 5.11.0 == the `aipu-5.11.0` tree in `cix-npu-driver_2.0.1.deb`
  == the `cix-drivers-dkms` npu submodule at tag `0.2.1-3` (all
  byte-identical), and is Radxa's currently released stack
  (`cd8180-bookworm` still ships `cix-noe-umd` 2.0.2). Flake input
  `npu-driver-5_11_0`, commit `a1b161f`.
- **KMD 6.0.1** ("2026Q2 RC4") is an unreleased dev snapshot ahead of any
  released userspace. Kept as `aipu-6_0_1` so the 7.x port work isn't
  lost; revisit when a matching UMD ships. Flake input `npu-driver-6_0_1`,
  commit `25b55cc`.

Both driver sources are `flake = false` inputs — commits in
`cixtech/cix_opensource__npu_driver` (the npu submodule of
`radxa-pkg/cix-drivers-dkms`); the driver itself is in that repo's
`driver/` subdir.

## The Linux 6.11 / 7.x compat patches

Both trees get the same class of fixes — see
`patches/aipu-{5.11.0,6.0.1}-linux-7.x.patch`:

- `MAX_ORDER` → `MAX_PAGE_ORDER` rename (6.0.1 only)
- `iommu_dma_cookie` layout: cast the domain cookie directly (since ~v6.7
  it *is* the `iova_domain`), keep the old private-struct path for < 6.7
- `MODULE_IMPORT_NS()` takes a string literal since v6.13
- drop `IRQF_ONESHOT` on an IRQ with no thread_fn (trips `WARN_ON_ONCE`)
- void `pm_runtime_put` → `pm_runtime_put_sync`; void
  `platform_driver::remove`
- devfreq block gated off (BSP-only SCMI perf-domain helpers)

The vendor Makefile is also replaced with a single root `Kbuild` (see
`aipu.nix`) so kbuild applies the `-I` / `-D` flags to every object,
including the sources under `armchina-npu/{sky1,zhouyi}/`.

## Known minor issues

- Reload (not fresh boot) warns `Unbalanced pm_runtime_enable!` ×3 on the
  core devices — a pre-existing asymmetry in the ACPI remove path. Benign.
- No NPU DVFS — devfreq is disabled; needs an SCMI perf-domain port.
- BTF generation is skipped (`kernel.dev` has no `vmlinux`).

## Compiling your own models

The `.cix` graphs consumed by `NOE_Engine` are produced by **CixBuilder**
(`AIPUBuilder`), the ONNX / TF / PyTorch → `.cix` compiler, which is an
**x86_64 host** tool and is not packaged here. MobileNet-V2 compiled with
CixBuilder 6.1.3407 classifies correctly on this stack and matches
`ai_model_hub`'s prebuilt graph.

## Not done

- devfreq / SCMI perf-domain port (the NPU runs at a fixed clock).
- Upstreaming the 7.x patches to `radxa-pkg/cix-drivers-dkms`.

## Licensing

- The `aipu` kernel driver source is **GPL-2.0-only** (upstream ArmChina /
  cixtech).
- `cix-noe-umd` / `libnoe` / `NOE_Engine` are redistributed from Radxa's
  apt repo under their own (Apache-2.0) terms.
- The packaging in this repo (the `.nix` files, patches, `smoketest.c`,
  `inference/`, scripts) is MIT — see `LICENSE`.
