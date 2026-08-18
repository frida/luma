.PHONY: build run clean bundle screenshots install uninstall render-tests soak

# SwiftPM's bundled .pc finder only consults the directories listed in
# PKG_CONFIG_PATH and the toolchain's primary compiled-in path; it
# misses the additional fallbacks that libpkgconf probes (e.g.
# /usr/local/lib64/pkgconfig on Fedora). Ask the system pkg-config
# where each module we care about actually lives and forward those
# directories so SwiftPM can find the same .pc files.
PKG_CONFIG_MODULES := frida-core-1.0 r_core librsvg-2.0
PKG_CONFIG_DIRS := $(sort $(foreach m,$(PKG_CONFIG_MODULES),$(shell pkg-config --variable=pcfiledir $(m))))
SYSTEM_PKG_CONFIG_PATH := $(subst $(eval) ,:,$(strip $(PKG_CONFIG_DIRS)))
export PKG_CONFIG_PATH := $(if $(PKG_CONFIG_PATH),$(PKG_CONFIG_PATH):)$(SYSTEM_PKG_CONFIG_PATH)
export USE_SYSTEM_FRIDA := 1

PROJECT_ROOT := $(abspath ..)

LOCAL_SHADER_TOOLCHAIN := $(PROJECT_ROOT)/artifacts/ShaderToolchain.xcframework
ifneq ($(wildcard $(LOCAL_SHADER_TOOLCHAIN)),)
export SHADER_TOOLCHAIN_ROOT := artifacts/ShaderToolchain.xcframework
endif

PHARO_IMAGE := ../Sources/LumaCore/Resources/pharo-image/SwiftyPharo.image
PHARO_SOURCE := $(PROJECT_ROOT)/../SwiftyPharo

# Only Apple platforms have a published VM to link against; everywhere else
# SwiftyPharo asks pkg-config for one, and no distribution packages it. Build it
# into .build unless the system already has it, so a fresh clone needs nothing
# but the usual toolchain.
ifneq ($(shell uname -s),Darwin)
PHARO_VM_PLATFORM := $(if $(findstring MINGW,$(shell uname -s)),windows,linux)
PHARO_VM_PREFIX := $(PROJECT_ROOT)/.build/pharo-vm
PHARO_VM_PC := $(PHARO_VM_PREFIX)/lib/pkgconfig/pharo-vm.pc
PHARO_VM := $(if $(shell pkg-config --exists pharo-vm && echo installed),,$(PHARO_VM_PC))
export PKG_CONFIG_PATH := $(PKG_CONFIG_PATH):$(PHARO_VM_PREFIX)/lib/pkgconfig
endif

AGENT_BUNDLE := $(PROJECT_ROOT)/Sources/LumaCore/Generated/LumaAgent.swift
TYPINGS_BUNDLE := $(PROJECT_ROOT)/Sources/LumaCore/Generated/LumaTypings.swift
AGENT_STAGING := $(PROJECT_ROOT)/.build/AgentStaging

AGENT_SOURCES := \
	$(shell find $(PROJECT_ROOT)/Agent -type f \( -name '*.ts' -o -name '*.json' \) 2>/dev/null) \
	$(PROJECT_ROOT)/Sources/LumaBundleCompiler/main.swift

SHADER_BUNDLE := $(PROJECT_ROOT)/Sources/LumaCore/Generated/ShaderEffects.swift
SHADER_SOURCES := $(wildcard $(PROJECT_ROOT)/Shaders/*.frag.glsl)

bundle: $(AGENT_BUNDLE) $(TYPINGS_BUNDLE) $(SHADER_BUNDLE)

$(AGENT_BUNDLE): $(AGENT_SOURCES) $(PROJECT_ROOT)/Agent/bundle.json
	swift run --package-path $(PROJECT_ROOT) LumaBundleCompiler \
	    --config       "$(PROJECT_ROOT)/Agent/bundle.json" \
	    --project-root "$(PROJECT_ROOT)" \
	    --staging-dir  "$(AGENT_STAGING)"

$(TYPINGS_BUNDLE): $(AGENT_BUNDLE)

$(SHADER_BUNDLE): $(SHADER_SOURCES) $(PROJECT_ROOT)/Sources/LumaShaderCompiler/main.swift
	swift run --package-path $(PROJECT_ROOT) LumaShaderCompiler \
	    --shader-dir "$(PROJECT_ROOT)/Shaders" \
	    --swift-out  "$@"

soak: build
	LUMA_SOAK=$(LUMA_SOAK) LUMA_SOAK_SECONDS=$(or $(SECONDS),180) \
	    .build/debug/LumaGtk

render-tests: build
	LUMA_RENDER_TESTS=$(CURDIR)/build/render-tests .build/debug/LumaGtk

# A .pc carries no rpath -- SwiftPM rejects one -- so a VM built here has to be
# named on the link line to be found again at run time.
PHARO_VM_RPATH := $(if $(PHARO_VM),-Xlinker -rpath -Xlinker $(PHARO_VM_PREFIX)/lib)

build: bundle $(PHARO_IMAGE) $(PHARO_VM)
	swift build $(SWIFT_BUILD_FLAGS) $(PHARO_VM_RPATH)

ifneq ($(PHARO_VM_PC),)
# Resolving first is what puts the script on disk, and resolving does not need
# the VM that the script goes on to build.
$(PHARO_VM_PC):
	@if [ -d "$(PHARO_SOURCE)/tools" ]; then \
	    tools="$(PHARO_SOURCE)"; \
	else \
	    swift package resolve; \
	    tools="$(CURDIR)/.build/checkouts/SwiftyPharo"; \
	fi; \
	echo "Building the Pharo VM into $(PHARO_VM_PREFIX)"; \
	DESTDIR= PREFIX="$(PHARO_VM_PREFIX)" PLATFORM=$(PHARO_VM_PLATFORM) "$$tools/tools/build-vm.sh"
endif

$(PHARO_IMAGE):
	$(PROJECT_ROOT)/scripts/stage-pharo-image.sh

run: build
	./.build/debug/LumaGtk

screenshots: build
	mkdir -p screenshots
	scripts/capture-screenshots.sh screenshots

PREFIX ?= /usr/local
BINDIR := $(PREFIX)/bin
DATADIR := $(PREFIX)/share

ICON_SIZES := 32 48 64 128 256 512

install: build
	install -Dm755 .build/debug/LumaGtk $(DESTDIR)$(BINDIR)/luma
	install -Dm644 data/re.frida.Luma.desktop $(DESTDIR)$(DATADIR)/applications/re.frida.Luma.desktop
	install -Dm644 data/re.frida.Luma.xml $(DESTDIR)$(DATADIR)/mime/packages/re.frida.Luma.xml
	for size in $(ICON_SIZES); do \
	    install -Dm644 data/icons/hicolor/$${size}x$${size}/apps/re.frida.Luma.png \
	        $(DESTDIR)$(DATADIR)/icons/hicolor/$${size}x$${size}/apps/re.frida.Luma.png; \
	done
	-update-mime-database $(DESTDIR)$(DATADIR)/mime 2>/dev/null
	-update-desktop-database $(DESTDIR)$(DATADIR)/applications 2>/dev/null
	-gtk-update-icon-cache -f -t $(DESTDIR)$(DATADIR)/icons/hicolor 2>/dev/null

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/luma
	rm -f $(DESTDIR)$(DATADIR)/applications/re.frida.Luma.desktop
	rm -f $(DESTDIR)$(DATADIR)/mime/packages/re.frida.Luma.xml
	for size in $(ICON_SIZES); do \
	    rm -f $(DESTDIR)$(DATADIR)/icons/hicolor/$${size}x$${size}/apps/re.frida.Luma.png; \
	done
	-update-mime-database $(DESTDIR)$(DATADIR)/mime 2>/dev/null
	-update-desktop-database $(DESTDIR)$(DATADIR)/applications 2>/dev/null
	-gtk-update-icon-cache -f -t $(DESTDIR)$(DATADIR)/icons/hicolor 2>/dev/null

clean:
	swift package clean
	rm -rf .build
