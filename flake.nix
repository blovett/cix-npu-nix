{
  description = "CIX SKY1 / Radxa Orion O6 NPU: aipu kernel module + NOE userspace";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  # ArmChina Zhouyi (aipu) NPU driver sources. Both are commits in
  # cixtech/cix_opensource__npu_driver (the npu submodule of radxa-pkg/
  # cix-drivers-dkms); the driver itself is in the driver/ subdir.
  #
  # a1b161f = "CIX P1 2025Q3" == the aipu-5.11.0 tree in the SDK's
  #           cix-npu-driver_2.0.1.deb; matches cix-noe-umd 2.0.2 / CixBuilder 6.1.
  # 25b55cc = "CIX P1 2026Q2 RC4"; newer, no matching released userspace.
  inputs.npu-driver-5_11_0 = {
    url = "github:cixtech/cix_opensource__npu_driver/a1b161f868f4019c4a1e5c843b0f5c93131e7726";
    flake = false;
  };
  inputs.npu-driver-6_0_1 = {
    url = "github:cixtech/cix_opensource__npu_driver/25b55cc08ec735093b5808c7cd0723f1a128c645";
    flake = false;
  };

  outputs =
    { self, nixpkgs, npu-driver-5_11_0, npu-driver-6_0_1, ... }:
    let
      system = "aarch64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      kernel = pkgs.linuxPackages_latest.kernel;

      mkAipu = args: pkgs.callPackage ./aipu.nix ({ inherit kernel; } // args);

      aipu = mkAipu {
        kmdVersion = "5.11.0";
        src = npu-driver-5_11_0;
        kernelPatch = ./patches/aipu-5.11.0-linux-7.x.patch;
      };
      aipu-6_0_1 = mkAipu {
        kmdVersion = "6.0.1";
        src = npu-driver-6_0_1;
        kernelPatch = ./patches/aipu-6.0.1-linux-7.x.patch;
      };

      noe = pkgs.callPackage ./noe-umd.nix { };

      # MobileNet-V2 demo: CixBuilder-compiled graph + a sample ImageNet
      # image, from the version-matched ai_model_hub (2025Q3) on ModelScope.
      msBase = "https://www.modelscope.cn/models/cix/ai_model_hub_25_Q3/resolve/master/models/ComputeVision/Image_Classification/onnx_mobilenet_v2";
      mobilenetCix = pkgs.fetchurl {
        url = "${msBase}/mobilenet_v2.cix";
        hash = "sha256-IrcHM0csCLZDfAyutesIhbHfzDQ7a1i2bAISnIGXJmw=";
      };
      sampleImage = pkgs.fetchurl {
        url = "${msBase}/test_data/ILSVRC2012_val_00002899.JPEG";
        hash = "sha256-PUG9YDsfXMzTYUDwQoXlBB/er1MuRqE4Lq5roc7w7ms=";
      };
      inferPython = pkgs.python312.withPackages (ps: [
        noe.libnoe noe.noe-engine ps.numpy ps.pillow
      ]);
      infer-mobilenet = pkgs.writeShellApplication {
        name = "infer-mobilenet";
        runtimeInputs = [ inferPython ];
        text = ''
          export PYTHONPATH=${./inference}''${PYTHONPATH:+:$PYTHONPATH}
          # First arg is the image unless it looks like a flag (e.g. --runs N),
          # in which case everything is passed straight through to the script.
          # A bad image path reaches the script and fails there, rather than
          # silently classifying the bundled sample.
          if [ "$#" -gt 0 ] && [ "''${1#-}" = "$1" ]; then
            img="$1"; shift
          else
            img="${sampleImage}"
          fi
          exec python3 ${./inference}/infer_mobilenet.py \
            --model ${mobilenetCix} \
            --image "$img" "$@"
        '';
      };
    in
    {
      packages.${system} = {
        default = aipu;
        inherit aipu aipu-6_0_1 infer-mobilenet;
        inherit (noe) cix-noe-umd libnoe noe-engine noe-smoketest;
        noe-python = pkgs.python312.withPackages (ps: [ noe.libnoe noe.noe-engine ]);
      };

      apps.${system} = {
        default = {
          type = "app";
          program = "${infer-mobilenet}/bin/infer-mobilenet";
          meta.description = "Run MobileNet-V2 ImageNet inference on the NPU";
        };
      };

      # `nix develop` -> a C toolchain for building smoketest.c against libnoe
      # plus a Python carrying the NOE bindings for the inference scripts.
      # libnoe is on PKG_CONFIG_PATH / LD_LIBRARY_PATH so builds find it with
      # no extra flags.
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.gcc
          pkgs.pkg-config
          pkgs.binutils   # nm, objdump, readelf
          pkgs.patchelf
          inferPython     # python3 + libnoe + NOE_Engine + numpy + pillow
        ];
        env.PKG_CONFIG_PATH = "${noe.cix-noe-umd}/lib/pkgconfig";
        shellHook = ''
          export LD_LIBRARY_PATH="${noe.cix-noe-umd}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          export PYTHONPATH="$PWD/inference''${PYTHONPATH:+:$PYTHONPATH}"
        '';
      };

      # Wire into a NixOS config: add this flake as an input with
      #   inputs.cix-npu.inputs.nixpkgs.follows = "nixpkgs";
      # then put cix-npu.nixosModules.default in the modules list.
      nixosModules.default =
        { config, lib, pkgs, ... }:
        let
          aipuMod = pkgs.callPackage ./aipu.nix {
            kernel = config.boot.kernelPackages.kernel;
            kmdVersion = "5.11.0";
            src = npu-driver-5_11_0;
            kernelPatch = ./patches/aipu-5.11.0-linux-7.x.patch;
          };
          noe' = pkgs.callPackage ./noe-umd.nix { };
        in
        {
          boot.extraModulePackages = [ aipuMod ];
          boot.kernelModules = [ "aipu" ];
          # Just the self-contained probe tool. The C lib and Python env are
          # heavier / dev-oriented - get them with `nix build`/`nix shell`
          # against this flake (.#cix-noe-umd, .#noe-python).
          environment.systemPackages = [ noe'.noe-smoketest ];
        };

      nixosModules.aipu = self.nixosModules.default;
    };
}
