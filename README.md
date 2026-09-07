# WorkBuddy Nix 打包

由官方 deb（`WorkBuddy-linux-x64-deb-5.5.3.37748631-104760a2.deb`）打包，
打包范式参考 nixpkgs 官方 [`qq`](https://github.com/NixOS/nixpkgs/blob/nixos-unstable/pkgs/by-name/qq/qq/package.nix)
（`autoPatchelfHook` + `makeShellWrapper` + `wrapGAppsHook3` + `dontWrapGApps`）。

## 文件

| 文件 | 说明 |
|---|---|
| `flake.nix` | flake 入口，提供 `packages.default` / `workbuddy-fhs` / `apps.default` |
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

## 升级

改 `package.nix` 里三个值：

```nix
version   = "5.5.3.37748631";   # 新版本号
buildHash = "104760a2";         # deb 文件名里的 build hash
sha256    = "...";              # 新文件哈希
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

## 可调参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `commandLineArgs` | `""` | 追加给 Electron 的命令行参数 |
| `disableSandbox` | `true` | 加 `--no-sandbox`。Nix store 内 `chrome-sandbox` 无法 setuid，默认关闭 |

**保留 Chromium 沙箱**（NixOS）：

```nix
security.wrappers.workbuddy-sandbox = {
  source = "${pkgs.workbuddy}/opt/WorkBuddy/chrome-sandbox";
  owner = "root";
  group = "root";
  setuid = true;
  permissions = "u+rx,g+x,o+x";
};
```

然后 `workbuddy.override { disableSandbox = false; }`。

## FHS 兜底（可选）

nixpkgs 官方对 `qq`、`wemeet` 都不用 FHS，本包也不默认兜。
若你遇到 patchelf 解决不了的问题（缺 FHS 路径、GL 异常），自己包一层即可：

```nix
(pkgs.buildFHSUserEnv {
  name = "workbuddy-fhs";
  targetPkgs = p: [ pkgs.workbuddy ];
  runScript = "workbuddy";
}).env
```

与 nixpkgs QQ 一致，通过 `NIXOS_OZONE_WL` 控制：

```nix
environment.sessionVariables.NIXOS_OZONE_WL = "1";
```

## 已知问题

1. **sha256**：官方 `/v2/update` 接口返回的 `sha256hash`（`f6451117...`）与 CDN 实际文件
   （`c5db5f26...`）不一致。本包用的是实测值。若你本地构建报 hash mismatch，
   用 `nix-prefetch-url` 重取即可。
2. **自动更新**：Linux 版 WorkBuddy 检测到新版本只跳转官网/应用商店，不自行下载安装，
   所以 Nix 包不会自我覆盖——这是好事，版本完全由 nix 控制。
3. **构建体量**：deb 410 MB，内含 node/python 运行时与 59 个 ELF，
   `autoPatchelf` 会全部处理，首次构建较慢。已设 `autoPatchelfIgnoreMissingDeps = true`
   避免个别 .so 缺依赖导致构建失败。
4. 若启动报缺库或 GL 相关错误，用 `packages.workbuddy-fhs`（FHS 环境版）兜底。

## 验证情况

- 已在沙箱中实际安装并运行官方 deb（xvfb），确认应用可正常启动、更新检查正常。
- 本 nix derivation **尚未实际构建**（沙箱内 nix 未安装完成）。构建如遇问题，
  多数是缺运行时依赖，按报错往 `buildInputs` 补即可。
