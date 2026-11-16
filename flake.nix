{
  description = "overshoot";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          # mkShellNoCC: mkShell exports SDKROOT/DEVELOPER_DIR for the nixpkgs Apple SDK,
          # which breaks xcodebuild and Zig's SDK detection.
          default = pkgs.mkShellNoCC {
            packages = [
              pkgs.zig_0_17
              pkgs.xcodegen
            ];
          };
        }
      );
    };
}
