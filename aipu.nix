# ArmChina Zhouyi V3 (aipu) NPU driver for CIX SKY1 / Radxa Orion O6,
# built out-of-tree against the running kernel.
#
# Parameterised over the KMD source revision, because the ioctl ABI
# (struct aipu_cap, ...) differs between KMD releases and must match the
# userspace (cix-noe-umd / CixBuilder):
#
#   kmdVersion = "5.11.0"  <- "CIX P1 2025Q3"; matches cix-noe-umd 2.0.2 and
#                             the aipu-5.11.0 tree in cix-npu-driver_2.0.1.deb
#   kmdVersion = "6.0.1"   <- "CIX P1 2026Q2"; unreleased dev snapshot, no
#                             matching userspace yet
#
# `src` is cixtech/cix_opensource__npu_driver; the driver lives in driver/.
{ lib
, stdenv
, kernel
, kmdVersion
, src
, sourceRoot ? "source/driver"
, kernelPatch      # 7.x compat patch matching this source tree
}:

let
  kernelMakeFlags = builtins.filter
    (f: !(lib.hasPrefix "O=" f) && f != "--eval=undefine modules")
    kernel.makeFlags;

  kbuildDir = "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build";
in
stdenv.mkDerivation {
  pname = "aipu-npu";
  version = "${kmdVersion}-${kernel.modDirVersion}";

  inherit src sourceRoot;
  patches = [ kernelPatch ];

  nativeBuildInputs = kernel.moduleBuildDependencies;

  # The vendor top-level Makefile drives kbuild with a flat object list whose
  # sources all live in subdirectories, but keeps its -I / -D flags in that
  # Makefile's EXTRA_CFLAGS, which kbuild does not apply to sources under
  # armchina-npu/{sky1,zhouyi,...}. Replace it with one root Kbuild whose
  # ccflags-y covers every object. ZHOUYI_V3 / SKY1 / devfreq-off match the
  # dkms.conf (BUILD_NPU_DEVFREQ dropped - see the patch).
  postPatch = ''
    cat > Kbuild <<'EOF'
    obj-m := aipu.o

    ccflags-y += -I$(src)/armchina-npu -I$(src)/armchina-npu/include -I$(src)/armchina-npu/zhouyi
    ccflags-y += -DKMD_VERSION=\"@KMD@\"
    ccflags-y += -DBUILD_ZHOUYI_V3 -DCONFIG_ARMCHINA_NPU_ARCH_V3 -DCONFIG_SKY1

    aipu-y := \
      armchina-npu/sky1/sky1.o \
      armchina-npu/aipu.o \
      armchina-npu/aipu_common.o \
      armchina-npu/aipu_io.o \
      armchina-npu/aipu_irq.o \
      armchina-npu/aipu_job_manager.o \
      armchina-npu/aipu_mm.o \
      armchina-npu/aipu_dma_buf.o \
      armchina-npu/aipu_priv.o \
      armchina-npu/aipu_tcb.o \
      armchina-npu/zhouyi/zhouyi.o \
      armchina-npu/zhouyi/v3.o \
      armchina-npu/zhouyi/v3_priv.o
    EOF
    sed -i -e 's/^    //' -e 's/@KMD@/${kmdVersion}/' Kbuild
  '';

  preBuild = ''
    makeFlagsArray+=(-C ${kbuildDir} "M=$PWD" modules)
  '';

  makeFlags = kernelMakeFlags;

  installPhase = ''
    runHook preInstall
    install -D aipu.ko "$out/lib/modules/${kernel.modDirVersion}/extra/aipu.ko"
    runHook postInstall
  '';

  meta = with lib; {
    description = "ArmChina Zhouyi V3 (aipu) NPU driver for CIX SKY1 (Radxa Orion O6), KMD ${kmdVersion}";
    license = licenses.gpl2Only;
    platforms = [ "aarch64-linux" ];
  };
}
