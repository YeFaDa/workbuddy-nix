{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  makeShellWrapper,
  wrapGAppsHook3,

  # 运行时依赖（同时供 autoPatchelf 与 wrapper 使用）
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  cairo,
  cups,
  glib,
  gtk3,
  libdrm,
  libgbm,
  libGL,
  libkrb5,
  libnotify,
  libpulseaudio,
  libsecret,
  libuuid,
  libxkbcommon,
  mesa,
  nspr,
  nss,
  pango,
  systemd,
  util-linux,
  xdg-utils,
  xorg,

  # 额外开关
  commandLineArgs ? "",
  # Electron 的 chrome-sandbox 在 Nix 下无法 setuid，默认关闭沙箱。
  # 若你用 NixOS 的 security.wrappers 给 chrome-sandbox 配了 setuid，
  # 可设为 false 以保留 Chromium 沙箱。
  disableSandbox ? true,
}:

stdenv.mkDerivation rec {
  pname = "workbuddy";
  version = "5.5.3.37748631";
  # deb 文件名中的 build hash，升级时需同步修改
  buildHash = "104760a2";

  # 官方同时提供 x64 与 arm64 的 deb，两个架构的哈希不同
  selectSystem = attrs:
    attrs.${stdenv.hostPlatform.system}
      or (throw "workbuddy: ${stdenv.hostPlatform.system} is not supported");

  source = selectSystem {
    x86_64-linux = {
      arch = "x64";
      sha256 = "c5db5f269561822c9b0ac16891e73b90056dac4a134369700036deae9277b062";
    };
    aarch64-linux = {
      arch = "arm64";
      sha256 = "a0ca12999238a9f4149998447516d9be5570a7f55c7ac0b540c35a3ec83d7821";
    };
  };

  src = fetchurl {
    url = "https://download.codebuddy.cn/workbuddy/saas/linux-${source.arch}-deb/WorkBuddy-linux-${source.arch}-deb-${version}-${buildHash}.deb";
    # 实测哈希。官方 /v2/update 接口返回的 sha256hash 与 CDN 实际文件不符
    # （x64、arm64 都不一致），不要直接填接口给的值。
    sha256 = source.sha256;
  };

  nativeBuildInputs = [
    autoPatchelfHook
    makeShellWrapper
    wrapGAppsHook3
    dpkg
  ];

  buildInputs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    cairo
    cups
    glib
    gtk3
    libdrm
    libgbm
    libkrb5
    libnotify
    libpulseaudio
    libsecret
    libuuid
    libxkbcommon
    mesa
    nspr
    nss
    pango
    util-linux
    xorg.libX11
    xorg.libXcomposite
    xorg.libXdamage
    xorg.libXext
    xorg.libXfixes
    xorg.libXrandr
    xorg.libxcb
    xorg.libXScrnSaver
    xorg.libXtst
  ];

  # 内置 node/python 运行时等 .so 依赖未必都在 nixpkgs 中，缺了不应让构建失败
  autoPatchelfIgnoreMissingDeps = true;

  runtimeDependencies = map lib.getLib [
    systemd
    libkrb5
  ];

  dontWrapGApps = true;

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x $src .
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp -r opt $out/opt
    cp -r usr/share $out/share

    substituteInPlace $out/share/applications/workbuddy.desktop \
      --replace-fail "/opt/WorkBuddy/workbuddy" "$out/bin/workbuddy"

    makeShellWrapper $out/opt/WorkBuddy/workbuddy $out/bin/workbuddy \
      --prefix XDG_DATA_DIRS : "$GSETTINGS_SCHEMAS_PATH" \
      --prefix LD_LIBRARY_PATH : "${
        lib.makeLibraryPath [
          libGL
          libuuid
          libsecret
          xorg.libXScrnSaver
          xorg.libXtst
        ]
      }" \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform=wayland --enable-features=WaylandWindowDecorations --enable-wayland-ime=true --wayland-text-input-version=3}}" \
      --add-flags ${lib.escapeShellArg commandLineArgs} \
      ${lib.optionalString disableSandbox "--add-flags --no-sandbox"} \
      "''${gappsWrapperArgs[@]}"

    runHook postInstall
  '';

  meta = {
    description = "WorkBuddy Desktop - AI Agent Desktop Application";
    homepage = "https://www.codebuddy.cn/work/";
    license = lib.licenses.unfree;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "workbuddy";
  };
}
