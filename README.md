# WorkBuddy Nix 打包

由官方 deb（`WorkBuddy-linux-x64-deb-5.5.4.38151288-1ca4889a.deb`）打包。

打包范式参考两处：

- nixpkgs 官方 [`qq`](https://github.com/NixOS/nixpkgs/blob/nixos-unstable/pkgs/by-name/qq/qq/package.nix)
  （`autoPatchelfHook` + `makeWrapper` + `wrapGAppsHook3` + `dontWrapGApps`）
- AUR 的 [`workbuddy`](https://aur.archlinux.org/packages/workbuddy) PKGBUILD
  （系统 electron 启动 + better-sqlite3 替换）

## 文件

| 文件 | 说明 |
|---|---|
| `flake.nix` | flake 入口，提供 `packages.default` / `apps.default` |
| `package.nix` | 主 derivation，可用 `callPackage` 直接引入 |

## 用法

**临时试用**

```bash
nix run github:YeFaDa/workbuddy-nix
```

**NixOS**

```nix
# flake.nix
inputs.workbuddy.url = "github:YeFaDa/workbuddy-nix";

# configuration.nix
environment.systemPackages = [ inputs.workbuddy.packages.${pkgs.system}.default ];
```

**home-manager**

```nix
home.packages = [ inputs.workbuddy.packages.${pkgs.system}.default ];
```

**不用 flake**

```nix
workbuddy = pkgs.callPackage ./workbuddy-nix/package.nix { };
```

需要 `allowUnfree = true`（WorkBuddy 为专有软件）。

## 与官方 deb 的四处关键差异

### 1. 用系统 electron 启动，而不是自带的

官方 deb 里的 `opt/WorkBuddy/workbuddy` 自带 **Electron 37.10.3**。该版本在
niri 等 Wayland 合成器下读不到 xdg-desktop-portal 的 `prefer-dark`，
导致应用无法跟随系统深色模式（QQ、bilibili 等用系统 electron 的包则正常）。

本包改为用 nixpkgs 的 `electron` 打开解包后的 app 目录：

```nix
makeWrapper ${lib.getExe electron} $out/bin/workbuddy \
  --add-flags "$out/opt/WorkBuddy/resources/app.asar.unpacked" \
  --set-default ELECTRON_FORCE_IS_PACKAGED 1 \
  --set-default ELECTRON_IS_DEV 0
```

### 2. 解包 app.asar

这是替换 better-sqlite3 能生效的前提。只换 `app.asar.unpacked` 里的文件
**不生效**：应用加载的是 **asar 内部**那份 JS，Node 在 asar 虚拟文件系统里
解析 `./binding` 时查的是 asar header 的条目，而 12.8.0 的 header 里没有
`lib/binding.js`，于是直接 `MODULE_NOT_FOUND`——unpacked 目录里就算放了
13.0.3 也用不上。

AUR 用 `asar e app.asar app.asar.unpacked || true`。本包没用 `asar` 工具：
官方只随 deb 附带当前平台需要的 unpacked 文件，header 里却还声明着
darwin/win32/arm64 那些（如 `cli/vendor/ripgrep/arm64-darwin/rg`），
`asar e` 一读到就直接 ENOENT 崩掉；那个 `|| true` 是硬吃这次中断，
解出来的目录其实并不完整。本包改为按 asar header 自己解包，缺失条目跳过，
完整解出 20237 个文件。

顺带：`electron` 直接打开目录时，`process.resourcesPath` 指向的是 electron
自己的安装目录而非 WorkBuddy 的资源目录，所以要把它替换成真实的 resources
路径（AUR 同样用 sed 处理，硬编码成 `/opt/WorkBuddy`；这里保留 `resources/`
层级，这样 `resources/runtime` 之类的路径也依旧对得上）。

### 3. better-sqlite3 换成 N-API 版本

deb 自带 **12.8.0**，预编译产物按 Node ABI 分目录：

```
app.asar.unpacked/node_modules/better-sqlite3/bin/linux-x64-136/better_sqlite3.node
```

`136` 是 Electron 37 的 `NODE_MODULE_VERSION`。换用系统 electron（43.x，ABI 更高）
后 ABI 不匹配，`require('better-sqlite3')` 会直接崩（进程级失败，异常都抛不出来）。

npm 上的 **13.0.3** 已迁移到 `node-addon-api`：产物是单个
`prebuilds/linux-x64.node`，导出 `napi_register_module_v1`，与 Electron/Node 版本无关；
`lib/binding.js` 也只按 `platform-arch` 拼文件名去找，不再查 ABI。

本包在 `installPhase` 里删掉自带的 12.8.0，换上 npm 的 13.0.3。

其余原生模块（`koffi`、`node-pty`、`@lydell/node-pty`、`@napi-rs/snappy`）
本身就是 N-API，跨版本通用，无需处理。

### 4. 删掉自带的 Electron 运行时和内置 node/python

既然用系统 electron 启动，deb 里那套 Electron 37 的文件就永远不会被加载，
直接删掉（AUR 的做法是干脆不安装）：

| 删掉的 | 大小 |
|---|---|
| `workbuddy` 主二进制 | 193 MB |
| `locales/`、`icudtl.dat`、`resources.pak` | 58 MB |
| `libGLESv2.so`、`libvk_swiftshader.so`、`libffmpeg.so` 等 | 16 MB |
| `LICENSES.chromium.html`、pak、snapshot 等 | 18 MB |
| **`resources/runtime/`（内置 node 199 MB + python 396 MB）** | 595 MB |

输出体积因此从 **1.7 GB 降到 819 MB**（解包会让少量文件膨胀，比 asar 形态略大）。

内置 `node`/`python` 是给 skills 和脚本执行用的。AUR 没装这部分（其
`optdepends` 里建议装 `nodejs-lts`）。本包默认也不装，需要的话：

```nix
workbuddy.override { keepBundledRuntime = true; }
```

## 升级

改 `package.nix` 里这些值：

```nix
version   = "5.5.4.38151288";       # 新版本号
buildHash = "1ca4889a";             # deb 文件名里的 build hash
# source.x86_64-linux.hash / source.aarch64-linux.hash  两个架构各自的哈希
```

查最新版本号：

```bash
curl -s "https://copilot.tencent.com/v2/update?platform=workbuddy-linux-x64-deb&version=0.0.0&channel=stable"
```

返回 200 时 `url` 字段即为新 deb 直链，`sha256hash` 字段为哈希（但见下方已知问题）。
取不到哈希时：

```bash
nix-prefetch-url https://download.codebuddy.cn/.../WorkBuddy-linux-x64-deb-<ver>-<hash>.deb
```

升级时顺带确认一下 better-sqlite3 的版本：如果官方哪天自己升到 13.x（产物出现在
`prebuilds/` 而不是 `bin/linux-x64-<abi>/`），替换逻辑就可以去掉了。

## 可调参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `commandLineArgs` | `""` | 追加给 Electron 的命令行参数 |
| `disableSandbox` | `true` | 加 `--no-sandbox`。Nix store 内 `chrome-sandbox` 无法 setuid，默认关闭 |
| `keepBundledRuntime` | `false` | 保留内置 node/python（`resources/runtime`，约 595 MB） |

**保留 Chromium 沙箱**：本包已删除自带的 `chrome-sandbox`（见差异 3），
所以不能再用 `${pkgs.workbuddy}/opt/WorkBuddy/chrome-sandbox`。需要沙箱时
改用系统 electron 自带的那个，再用 NixOS 的 `security.wrappers` 配 setuid，
然后 `workbuddy.override { disableSandbox = false; }`。

## FHS 兜底（可选）

nixpkgs 官方对 `qq`、`wemeet` 都不用 FHS，本包也不默认兜。
若遇到 patchelf 解决不了的问题（缺 FHS 路径、GL 异常），自己包一层：

```nix
(pkgs.buildFHSUserEnv {
  name = "workbuddy-fhs";
  targetPkgs = p: [ pkgs.workbuddy ];
  runScript = "workbuddy";
}).env
```

Wayland 输入法/窗口装饰通过 `NIXOS_OZONE_WL` 控制（与 nixpkgs QQ 一致）：

```nix
environment.sessionVariables.NIXOS_OZONE_WL = "1";
```

## 已知问题

1. **sha256**：官方 `/v2/update` 接口返回的 `sha256hash` 与 CDN 实际文件不一致
   （x64、arm64 都不一致）。本包用的是实测值。若本地构建报 hash mismatch，
   用 `nix-prefetch-url` 重取即可。
2. **自动更新**：Linux 版 WorkBuddy 检测到新版本只跳转官网/应用商店，不自行下载安装，
   所以 Nix 包不会自我覆盖——这是好事，版本完全由 nix 控制。
3. **构建体量**：deb 429 MB，输出 819 MB（`app.asar.unpacked` 占了绝大部分）。
   `autoPatchelf` 会处理其中几十个 ELF，首次构建较慢。已设
   `autoPatchelfIgnoreMissingDeps = true` 避免个别 .so 缺依赖导致构建失败。
   还能再挤约 101 MB（darwin 37 MB + win32 49 MB + musl 3 MB + 零散 12 MB），
   现在 app 已解包，删起来很容易，但 AUR 也没删这些，暂未做。
4. **启动时两条无害告警**，都不是本打包引入的：
   - `[DEP0040] DeprecationWarning: The punycode module is deprecated`
     ——Electron 43 自带 Node 24，`punycode` 已被标记弃用，纯告警。
   - `[wb-guest-protocol] wb.js bundle NOT found`——官方自己的未完成项。
     `main/index.js` 的注释里写着"Prod 打包时**需要**把 dist/wb.js 复制到
     resources 目录（TODO：加到 `build.ts` 或 electron-builder `extraResources`）"，
     即官方到现在也没把 wb-guest-sdk 打进包里（5.5.3 的官方 deb 同样没有
     `resources/wb-guest-sdk/`）。代码另有 CDN 兜底
     （`WB_GUEST_SDK_URL = https://www.workbuddy.cn/wb.js`），
     只影响扩展 iframe/webview 的**本地**加载。
5. 若启动报缺库或 GL 相关错误，用上面的 `buildFHSUserEnv` 兜底。

## 验证情况

- `nix build`（x86_64-linux）通过，输出 819 MB。
- 已确认输出中不含自带 electron 与 `resources/runtime`，wrapper 指向
  electron 43.4.1 + `resources/app.asar.unpacked`。
- 解包完整性已核对：`package.json`、`main/index.js`、`main/server.js` 均在，
  共 20237 个文件；`process.resourcesPath` 已全部替换为真实 resources 路径。
- better-sqlite3 替换已验证：13.0.3 的 `prebuilds/linux-x64.node` 在 ABI 137 环境下
  可正常 `require`；自带的 12.8.0 在同一环境下直接崩溃。
- **尚未在 niri 下实测深色模式是否跟随系统**——需要实际启动确认。
