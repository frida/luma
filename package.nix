{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  wrapGAppsHook4,
  libadwaita,
  webkitgtk_6_0,
  libzip,
  libnice,
  swift,
  adwaita-icon-theme,
  hicolor-icon-theme,
  libgee,
  libxml2,
  atk,
  sqlite,
  glib-networking,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "luma";
  version = "1.2.3";

  src = fetchurl {
    url = "https://github.com/frida/luma/releases/download/${finalAttrs.version}/luma-${finalAttrs.version}-ubuntu-24.04-x86_64.deb";
    hash = "sha256-7MG/70fVez9MOHc3FlSnbXCxE+8cB2czq1BFQrCT/B4=";
  };

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    wrapGAppsHook4
  ];

  buildInputs = [
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

  meta = {
    description = "The official Frida GUI";
    homepage = "https://luma.frida.re/";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "luma";
  };
})