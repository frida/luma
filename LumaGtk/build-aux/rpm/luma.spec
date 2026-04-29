Name:           luma
Version:        %{version}
Release:        1%{?dist}
Summary:        The official Frida GUI

License:        MIT
URL:            https://luma.frida.re/

BuildArch:      x86_64
AutoReq:        no
AutoProv:       no

Requires:       libadwaita
Requires:       webkitgtk6.0
Requires:       libzip
Requires:       libnice
Requires:       swift-lang

%description
Luma is a native app for interactive dynamic instrumentation,
built on Frida. Persistent sessions, a live REPL, pluggable
instruments, and real-time collaboration in a workspace that
remembers where you left off.

%prep

%build

%install
cp -a "%{_sourcedir}/stage/." "%{buildroot}/"

%files
/usr/bin/luma
/usr/lib/luma
/usr/share/applications/re.frida.Luma.desktop
/usr/share/mime/packages/re.frida.Luma.xml
/usr/share/icons/hicolor/*/apps/re.frida.Luma.png

%post
gtk-update-icon-cache -f /usr/share/icons/hicolor &>/dev/null || :
update-mime-database /usr/share/mime &>/dev/null || :
update-desktop-database /usr/share/applications &>/dev/null || :

%postun
if [ $1 -eq 0 ]; then
    gtk-update-icon-cache -f /usr/share/icons/hicolor &>/dev/null || :
    update-mime-database /usr/share/mime &>/dev/null || :
    update-desktop-database /usr/share/applications &>/dev/null || :
fi

%changelog
