{
  description = "The official Frida GUI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    {
      overlays.default = final: _: {
        luma = final.callPackage ./package.nix { };
      };
    } // flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        luma = pkgs.callPackage ./package.nix { };
      in
      {
        packages.default = self.packages.${system}.luma;
        packages.luma = luma;
      });
}
