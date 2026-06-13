{
  description = "The official Frida GUI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        packages.default = self.packages.${system}.luma;

        packages.luma = pkgs.stdenv.mkDerivation rec {
          pname = "luma";
          version = "0.12.3";

          src = pkgs.fetchurl {
            url = "https://github.com/frida/luma/releases/download/${version}/luma-${version}-ubuntu-24.04-x86_64.deb";
            hash = "sha256-ZgkBuIRvE/RFduqe8O/VW0HmFVTYUkh8+r6vqPZ1CbA=";
          };

          nativeBuildInputs = with pkgs; [
            dpkg
            autoPatchelfHook
            wrapGAppsHook4
          ];

          buildInputs = with pkgs; [
            libadwaita
            webkitgtk_6_0
            libzip
            libnice
            swift
            adwaita-icon-theme
            hicolor-icon-theme
            libgee
            libxml2
            atk
            sqlite
            glib-networking
          ];

          unpackPhase = "dpkg-deb -x $src .";

          installPhase = ''
            runHook preInstall
            mkdir -p $out
            cp -r usr/. $out/
            patchelf --replace-needed libzip.so.4 libzip.so $out/bin/luma
            patchelf --replace-needed libxml2.so.2 libxml2.so \
              $out/lib/luma/swift/libFoundationXML.so
            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "The official Frida GUI";
            homepage = "https://luma.frida.re/";
            license = licenses.mit;
            platforms = [ "x86_64-linux" ];
            mainProgram = "luma";
          };
        };
      });
}
