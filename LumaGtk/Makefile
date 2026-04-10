.PHONY: build run clean bundle screenshots install uninstall

# SwiftPM's bundled .pc finder only consults the directories listed in
# PKG_CONFIG_PATH and the toolchain's primary compiled-in path; it
# misses the additional fallbacks that libpkgconf probes (e.g.
# /usr/local/lib64/pkgconfig on Fedora). Ask the system pkg-config
# where each module we care about actually lives and forward those
# directories so SwiftPM can find the same .pc files.
PKG_CONFIG_MODULES := frida-core-1.0 r_core
PKG_CONFIG_DIRS := $(sort $(foreach m,$(PKG_CONFIG_MODULES),$(shell pkg-config --variable=pcfiledir $(m))))
SYSTEM_PKG_CONFIG_PATH := $(subst $(eval) ,:,$(strip $(PKG_CONFIG_DIRS)))
export PKG_CONFIG_PATH := $(if $(PKG_CONFIG_PATH),$(PKG_CONFIG_PATH):)$(SYSTEM_PKG_CONFIG_PATH)
export USE_SYSTEM_FRIDA := 1

PROJECT_ROOT := $(abspath ..)
AGENT_BUNDLE := $(PROJECT_ROOT)/Sources/LumaCore/Generated/LumaAgent.swift
AGENT_STAGING := $(PROJECT_ROOT)/.build/AgentStaging

AGENT_SOURCES := \
	$(shell find $(PROJECT_ROOT)/Agent -type f \( -name '*.ts' -o -name '*.json' \) 2>/dev/null) \
	$(PROJECT_ROOT)/Sources/LumaBundleCompiler/main.swift

bundle: $(AGENT_BUNDLE)

$(AGENT_BUNDLE): $(AGENT_SOURCES)
	swift run --package-path $(PROJECT_ROOT) luma-bundle-compiler \
	    --project-root "$(PROJECT_ROOT)" \
	    --swift-out    "$(AGENT_BUNDLE)" \
	    --staging-dir  "$(AGENT_STAGING)" \
	    --package frida-itrace@6.0.0 \
	    --agent  core      Agent/core/luma.ts \
	    --agent  drain     Agent/instruments/drain-agent.ts \
	    --module tracer    Agent/instruments/tracer.ts \
	    --module codeShare Agent/instruments/codeshare.ts

build: bundle
	swift build $(SWIFT_BUILD_FLAGS)

run: build
	./.build/debug/LumaGtk

screenshots: build
	mkdir -p screenshots
	scripts/capture-screenshots.sh screenshots

PREFIX ?= /usr/local
BINDIR := $(PREFIX)/bin
DATADIR := $(PREFIX)/share

install: build
	install -Dm755 .build/debug/LumaGtk $(DESTDIR)$(BINDIR)/luma
	install -Dm644 data/re.frida.Luma.desktop $(DESTDIR)$(DATADIR)/applications/re.frida.Luma.desktop
	install -Dm644 data/re.frida.Luma.xml $(DESTDIR)$(DATADIR)/mime/packages/re.frida.Luma.xml
	-update-mime-database $(DESTDIR)$(DATADIR)/mime 2>/dev/null
	-update-desktop-database $(DESTDIR)$(DATADIR)/applications 2>/dev/null

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/luma
	rm -f $(DESTDIR)$(DATADIR)/applications/re.frida.Luma.desktop
	rm -f $(DESTDIR)$(DATADIR)/mime/packages/re.frida.Luma.xml
	-update-mime-database $(DESTDIR)$(DATADIR)/mime 2>/dev/null
	-update-desktop-database $(DESTDIR)$(DATADIR)/applications 2>/dev/null

clean:
	swift package clean
	rm -rf .build
