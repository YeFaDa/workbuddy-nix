{
  description = "WorkBuddy Desktop (Tencent) — 由官方 deb 打包的 Nix 包";

  # 只依赖 nixpkgs，不引入 flake-utils：本包仅支持 Linux 两个架构，
  # 用 lib.genAttrs 手写即可，没必要为便利函数多拉一个 input。
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forEachSystem = f:
        nixpkgs.lib.genAttrs systems (system:
          f {
            inherit system;
            pkgs = import nixpkgs {
              inherit system;
              config.allowUnfree = true;
            };
          });
    in
    {
      packages = forEachSystem ({ pkgs, ... }:
        let workbuddy = pkgs.callPackage ./package.nix { };
        in {
          workbuddy = workbuddy;
          default = workbuddy;
        });

      apps = forEachSystem ({ pkgs, ... }: {
        default = {
          type = "app";
          program = "${pkgs.callPackage ./package.nix { }}/bin/workbuddy";
        };
      });
    };
}
