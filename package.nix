{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  wrapGAppsHook4,
  libadwaita,
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
  libffi,
  openssl,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "luma";
  version = "3.0.0";

  src = fetchurl {
    url = "https://github.com/frida/luma/releases/download/${finalAttrs.version}/luma-${finalAttrs.version}-ubuntu-24.04-x86_64.deb";
    hash = "sha256-6yfyRikN/J7IVPLctLfZOh0bNkoc0AZQBSdfZiR1GbY=";
  };

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    wrapGAppsHook4
  ];

  buildInputs = [
    libadwaita
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
    libffi
    openssl
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