# CIX NOE user-mode driver (userspace side of the NPU stack).
#
# Repackages cix-noe-umd_2.0.2_arm64.deb into:
#   - cix-noe-umd           : C library libnoe.so + header + pkg-config
#   - python312Packages.libnoe     : CPython bindings (self-contained;
#                                    the NOE runtime is statically linked in)
#   - python312Packages.noe-engine : NOE_Engine.EngineInfer high-level wrapper
#
# The deb is fetched from Radxa's cd8180-bookworm apt repo. Its payload
# (libnoe.so/.a, headers, wheels, .pc) is byte-identical to the deb in the
# 2025Q3 NOE SDK - only changelog.Debian.gz metadata differs. The SDK's
# CixBuilder wheel is an x86_64 *host* model compiler, not packaged here.
{ lib
, stdenv
, fetchurl
, dpkg
, autoPatchelfHook
, python312Packages
}:

let
  version = "2.0.2";
  deb = fetchurl {
    url = "https://radxa-repo.github.io/cd8180-bookworm/pool/main/c/cix-noe-umd/cix-noe-umd_${version}_arm64.deb";
    hash = "sha256-B+VRUaDvnhhLhv6j16y8UnwyDo2Cvq7i3dzTAolsEaE=";
  };

  # Raw extracted deb tree, so every sub-package can pick files out of it.
  noeFiles = stdenv.mkDerivation {
    pname = "cix-noe-umd-files";
    inherit version;
    src = deb;
    nativeBuildInputs = [ dpkg ];
    unpackPhase = "dpkg-deb -x $src .";
    installPhase = "cp -r . $out";
  };

  cix-noe-umd = stdenv.mkDerivation {
    pname = "cix-noe-umd";
    inherit version;
    src = noeFiles;

    nativeBuildInputs = [ autoPatchelfHook ];
    buildInputs = [ stdenv.cc.cc.lib ];

    installPhase = ''
      runHook preInstall

      install -Dm755 usr/share/cix/lib/libnoe.so $out/lib/libnoe.so
      install -Dm644 usr/share/cix/lib/libnoe.a  $out/lib/libnoe.a
      # the deb ships plain copies under versioned names; provide the usual links
      ln -s libnoe.so $out/lib/libnoe.so.0
      ln -s libnoe.so $out/lib/libnoe.so.0.6.0

      install -Dm644 usr/share/cix/include/npu/cix_noe_standard_api.h \
        $out/include/npu/cix_noe_standard_api.h

      mkdir -p $out/lib/pkgconfig
      cat > $out/lib/pkgconfig/cix-noe-umd.pc <<EOF
      prefix=$out
      exec_prefix=\''${prefix}
      libdir=\''${prefix}/lib
      includedir=\''${prefix}/include

      Name: cix-noe-umd
      Description: CIX NPU NOE user-mode driver
      Version: ${version}
      Libs: -L\''${libdir} -lnoe
      Libs.private: -lm -ldl -lpthread -lrt
      Cflags: -I\''${includedir}
      EOF

      runHook postInstall
    '';

    meta = with lib; {
      description = "CIX NPU NOE user-mode driver (libnoe)";
      license = licenses.asl20;
      platforms = [ "aarch64-linux" ];
    };
  };

  libnoe = python312Packages.buildPythonPackage {
    pname = "libnoe";
    version = "2.0.0";
    format = "wheel";
    src = "${noeFiles}/usr/share/cix/pypi/libnoe-2.0.0-py3-none-manylinux2014_aarch64.whl";

    nativeBuildInputs = [ autoPatchelfHook ];
    buildInputs = [ stdenv.cc.cc.lib ];

    pythonImportsCheck = [ "libnoe" ];

    meta = with lib; {
      description = "Python bindings for the CIX NPU NOE user-mode driver";
      license = licenses.asl20;
      platforms = [ "aarch64-linux" ];
    };
  };

  noe-engine = python312Packages.buildPythonPackage {
    pname = "noe-engine";
    version = "2.0.0";
    format = "wheel";
    src = "${noeFiles}/usr/share/cix/pypi/NOE_Engine-2.0.0-py3-none-manylinux2014_aarch64.whl";

    dependencies = [ libnoe python312Packages.numpy ];
    pythonImportsCheck = [ "NOE_Engine" ];

    meta = with lib; {
      description = "NOE_Engine inference wrapper for the CIX NPU";
      license = licenses.asl20;
      platforms = [ "aarch64-linux" ];
    };
  };
  noe-smoketest = stdenv.mkDerivation {
    pname = "noe-smoketest";
    inherit version;
    dontUnpack = true;
    buildInputs = [ cix-noe-umd ];
    buildPhase = ''
      $CC -O2 -Wall -o noe-smoketest ${./smoketest.c} -lnoe
    '';
    installPhase = "install -Dm755 noe-smoketest $out/bin/noe-smoketest";
    meta.description = "Minimal libnoe -> /dev/aipu smoke test for the CIX NPU";
  };
in
{
  inherit cix-noe-umd libnoe noe-engine noe-smoketest;
}
