{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  makeWrapper,
  wrapGAppsHook3,
  electron,
  python3,

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
  libx11,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxrandr,
  libxcb,
  libxscrnsaver,
  libxtst,
  mesa,
  nspr,
  nss,
  pango,
  systemd,
  util-linux,
  xdg-utils,

  # 额外开关
  commandLineArgs ? "",
  # Electron 的 chrome-sandbox 在 Nix 下无法 setuid，默认关闭沙箱。
  # 本包已删除自带的 chrome-sandbox；若要保留 Chromium 沙箱，需要改用系统
  # electron 自带的那个，并自行用 NixOS 的 security.wrappers 配 setuid。
  disableSandbox ? true,
  # 是否保留 deb 自带的 node/python 运行时（resources/runtime，约 595 MB）。
  # AUR 的 workbuddy 包不安装这部分。若你的 skills / 脚本执行依赖内置
  # node 或 python，设为 true 保留。
  keepBundledRuntime ? false,
}:

let
  # deb 文件名中的 build hash，升级时需同步修改
  buildHash = "1ca4889a";

  # 放在 let 里：mkDerivation 的属性最终都要能序列化成字符串，
  # 函数塞进属性集会报 "cannot coerce a function to a string"。
  selectSystem = attrs:
    attrs.${stdenv.hostPlatform.system}
      or (throw "workbuddy: ${stdenv.hostPlatform.system} is not supported");

  source = selectSystem {
    x86_64-linux = {
      arch = "x64";
      hash = "sha256-A9dWslnXCGwiCY+gd1iaAy1glI0d5zE0czYO7+EeJA8=";
    };
    aarch64-linux = {
      arch = "arm64";
      hash = "sha256-n/gbWeBBKlHAT23BGJ/9kuTdHJtMwNCym4xxEVlQXIc=";
    };
  };

  # better-sqlite3 替换源（两个架构共用，tarball 里同时含 linux-x64 与
  # linux-arm64 的预编译产物）。详见 installPhase 中的说明。
  betterSqlite3Src = fetchurl {
    url = "https://registry.npmjs.org/better-sqlite3/-/better-sqlite3-13.0.3.tgz";
    hash = "sha256-d+BRPcGkafs7zuxMf7WtP0AxCXh+2gW+BH7Bf9VoaMs=";
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "workbuddy";
  version = "5.5.4.38151288";

  src = fetchurl {
    url = "https://download.codebuddy.cn/workbuddy/saas/linux-${source.arch}-deb/WorkBuddy-linux-${source.arch}-deb-${finalAttrs.version}-${buildHash}.deb";
    # 实测哈希。官方 /v2/update 接口返回的 sha256hash 与 CDN 实际文件不符
    # （x64、arm64 都不一致），不要直接填接口给的值。
    hash = source.hash;
  };

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
    wrapGAppsHook3
    dpkg
    python3
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
    libx11
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxrandr
    libxcb
    libxscrnsaver
    libxtst
    mesa
    nspr
    nss
    pango
    util-linux
    xdg-utils
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

    # -------------------------------------------------------------------
    # 0) 丢掉自带的 Electron 运行时（约 285 MB）
    # -------------------------------------------------------------------
    # 既然用系统 electron 启动，deb 里这套 Electron 37 的文件永远不会被加载：
    # 主二进制 workbuddy 193 MB，加上 locales/、icudtl.dat、resources.pak、
    # libGLESv2.so、libvk_swiftshader.so、libffmpeg.so 等。
    # AUR 的做法是干脆不安装它们，这里同样删掉。
    #
    # 注意：这会让 README 里 security.wrappers 指向自带 chrome-sandbox 的写法失效，
    # 需要沙箱时得改用系统 electron 的那一个。
    pushd opt/WorkBuddy
    rm -f workbuddy \
      chrome-sandbox chrome_crashpad_handler \
      chrome_100_percent.pak chrome_200_percent.pak \
      icudtl.dat libEGL.so libGLESv2.so libffmpeg.so \
      libvk_swiftshader.so libvulkan.so.1 \
      resources.pak snapshot_blob.bin v8_context_snapshot.bin \
      LICENSE.electron.txt LICENSES.chromium.html \
      version vk_swiftshader_icd.json \
      resources/default_app.asar resources/apparmor-profile
    rm -rf locales
    popd

    # 内置 node/python 运行时（约 595 MB），默认不保留
    ${lib.optionalString (!keepBundledRuntime) ''
      rm -rf opt/WorkBuddy/resources/runtime
    ''}

    # ===================================================================
    # 以下处理参考 AUR 的 workbuddy 包（aur/workbuddy PKGBUILD）
    # ===================================================================

    # -------------------------------------------------------------------
    # 1) 解包 app.asar —— 这也是替换 better-sqlite3 能生效的前提
    # -------------------------------------------------------------------
    # 只换掉 app.asar.unpacked 里的文件是不够的：应用实际加载的是 asar 内部
    # 那份 JS（报错栈里是 app.asar/node_modules/.../lib/index.js）。Node 在
    # asar 虚拟文件系统里解析 ./binding 时，查的是 asar header 的条目，而
    # 12.8.0 的 header 里没有 lib/binding.js，于是直接 MODULE_NOT_FOUND
    # ——unpacked 目录里就算放了 13.0.3 也用不上。所以必须解包成真实目录。
    #
    # 解到 app.asar.unpacked（官方标记为 unpacked 的原生模块本来就在那），
    # 然后丢掉 app.asar。
    #
    # 不用 `asar e`：官方只随 deb 附带当前平台需要的 unpacked 文件，header 里
    # 却还声明着 darwin/win32/arm64 那些（如 cli/vendor/ripgrep/arm64-darwin/rg），
    # asar 读到它们直接 ENOENT 崩掉。AUR 是加 `|| true` 硬吃这个中断的，
    # 但那样解出来的目录并不完整。这里自己按 header 解包，缺的跳过。
    cat > unpack-asar.py <<'PYEOF'
import os, sys, json, struct

asar_path, dest = sys.argv[1], sys.argv[2]
with open(asar_path, 'rb') as f:
    header_len = struct.unpack('<II', f.read(8))[1]
    hb = f.read(header_len)
    json_len = struct.unpack('<I', hb[4:8])[0]
    header = json.loads(hb[8:8 + json_len])
    data_offset = 8 + header_len

    missing = []

    def walk(node, path):
        for name, ent in node.get('files', {}).items():
            full = os.path.join(path, name)
            if 'files' in ent:
                os.makedirs(full, exist_ok=True)
                walk(ent, full)
                continue
            os.makedirs(os.path.dirname(full), exist_ok=True)
            if ent.get('link'):
                if not os.path.lexists(full):
                    os.symlink(ent['link'], full)
                continue
            if ent.get('unpacked'):
                # 原生模块等本来就放在 app.asar.unpacked 里，已存在则跳过
                if not os.path.exists(full):
                    missing.append(os.path.relpath(full, dest))
                continue
            f.seek(data_offset + int(ent['offset']))
            with open(full, 'wb') as out:
                out.write(f.read(ent['size']))

    walk(header, dest)

print('unpacked asar; skipped missing unpacked entries:', len(missing))
for m in missing[:20]:
    print('  missing:', m)
PYEOF

    python3 unpack-asar.py \
      opt/WorkBuddy/resources/app.asar \
      opt/WorkBuddy/resources/app.asar.unpacked

    rm -f opt/WorkBuddy/resources/app.asar

    # -------------------------------------------------------------------
    # 2) 用 N-API 版的 better-sqlite3 替换 deb 自带的
    # -------------------------------------------------------------------
    # deb 里带的是 12.8.0，预编译产物按 Node ABI 分目录存放：
    #   .../better-sqlite3/bin/linux-x64-136/better_sqlite3.node
    # 136 是 Electron 37 的 NODE_MODULE_VERSION。一旦改用系统 electron
    # (43.x)，ABI 对不上，require('better-sqlite3') 直接 ERR_DLOPEN_FAILED。
    #
    # npm 上的 13.0.3 已迁移到 node-addon-api：产物是单个
    # prebuilds/linux-x64.node，导出 napi_register_module_v1，
    # 与 Electron/Node 版本无关；lib/binding.js 也只按 platform-arch
    # 拼文件名去 prebuilds/ 下找，不再查 ABI。
    #
    # 其余原生模块（koffi、node-pty、@lydell/node-pty、@napi-rs/snappy）
    # 本身就是 N-API，跨版本通用，无需替换。
    # -------------------------------------------------------------------
    _app=opt/WorkBuddy/resources/app.asar.unpacked
    chmod -R u+w $_app

    rm -rf $_app/node_modules/better-sqlite3
    mkdir -p bs3
    tar xzf ${betterSqlite3Src} -C bs3
    chmod -R u+w bs3/package
    mv bs3/package $_app/node_modules/better-sqlite3

    cp -r opt $out/opt
    cp -r usr/share $out/share

    # -------------------------------------------------------------------
    # 3) 把 process.resourcesPath 指向真实的 resources 目录
    # -------------------------------------------------------------------
    # electron 直接打开一个目录时（而不是打包的 app），resourcesPath 指向的是
    # electron 自己的安装目录，不是 WorkBuddy 的资源目录。AUR 用 sed 把它
    # 硬编码成 /opt/WorkBuddy；这里同样处理，但保留 resources/ 层级，
    # 这样 resources/runtime 之类的路径也依旧对得上。
    find $out/opt/WorkBuddy/resources/app.asar.unpacked -type f \
      -exec sed -i "s|process\.resourcesPath|'$out/opt/WorkBuddy/resources'|g" {} +

    # -------------------------------------------------------------------
    # 4) 用系统 electron 启动，而不是 deb 自带的 workbuddy 二进制
    # -------------------------------------------------------------------
    # 自带的是 Electron 37.10.3，在 niri 下读不到 xdg-desktop-portal 的
    # prefer-dark，无法跟随系统深色模式；换成 nixpkgs 的 electron 即可。
    # -------------------------------------------------------------------

    substituteInPlace $out/share/applications/workbuddy.desktop \
      --replace-fail "/opt/WorkBuddy/workbuddy" "$out/bin/workbuddy"

    makeWrapper ${lib.getExe electron} $out/bin/workbuddy \
      --argv0 "workbuddy" \
      --prefix XDG_DATA_DIRS : "$GSETTINGS_SCHEMAS_PATH" \
      --prefix LD_LIBRARY_PATH : "${
        lib.makeLibraryPath [
          libGL
          libuuid
          libsecret
          libxscrnsaver
          libxtst
        ]
      }" \
      --add-flags "$out/opt/WorkBuddy/resources/app.asar.unpacked" \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform=wayland --enable-features=WaylandWindowDecorations --enable-wayland-ime=true --wayland-text-input-version=3}}" \
      --set-default ELECTRON_FORCE_IS_PACKAGED 1 \
      --set-default ELECTRON_IS_DEV 0 \
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
})
