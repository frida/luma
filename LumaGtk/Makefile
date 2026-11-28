.PHONY: build run clean bundle version screenshots install uninstall render-tests soak swiftpm-pkg-config

# Machine-local overrides, such as FRIDA_SWIFT_ROOT pointing at a
# checkout of the bindings while a fix is being verified.
-include local.mk

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
IN_BUILD_ENVIRONMENT := $(PROJECT_ROOT)/Scripts/in-build-environment.sh

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

SWIFTPM_PKG_CONFIG_DIR := $(CURDIR)/.build/pkgconfig
export PKG_CONFIG_PATH := $(SWIFTPM_PKG_CONFIG_DIR):$(PKG_CONFIG_PATH)

GENERATED_DIR := $(PROJECT_ROOT)/Sources/LumaCore/Generated
AGENT_STAMP := $(GENERATED_DIR)/.agent.stamp
AGENT_STAGING := $(PROJECT_ROOT)/.build/AgentStaging

AGENT_SOURCES := \
	$(shell find $(PROJECT_ROOT)/Agent -type f \( -name '*.ts' -o -name '*.json' \) 2>/dev/null) \
	$(PROJECT_ROOT)/Sources/LumaBundleCompiler/main.swift

SHADER_BUNDLE := $(GENERATED_DIR)/ShaderEffects.swift
SHADER_STAMP := $(GENERATED_DIR)/.shaders.stamp
SHADER_SOURCES := $(wildcard $(PROJECT_ROOT)/Shaders/*.frag.glsl)

VERSION_SOURCE := $(GENERATED_DIR)/LumaVersion.swift

bundle: $(AGENT_STAMP) $(SHADER_STAMP) version

$(AGENT_STAMP): $(AGENT_SOURCES) $(PROJECT_ROOT)/Agent/bundle.json | swiftpm-pkg-config
	$(IN_BUILD_ENVIRONMENT) swift run --package-path $(PROJECT_ROOT) LumaBundleCompiler \
	    --config       "$(PROJECT_ROOT)/Agent/bundle.json" \
	    --project-root "$(PROJECT_ROOT)" \
	    --staging-dir  "$(AGENT_STAGING)"
	touch $@

$(SHADER_STAMP): $(SHADER_SOURCES) $(PROJECT_ROOT)/Sources/LumaShaderCompiler/main.swift | swiftpm-pkg-config
	$(IN_BUILD_ENVIRONMENT) swift run --package-path $(PROJECT_ROOT) LumaShaderCompiler \
	    --shader-dir "$(PROJECT_ROOT)/Shaders" \
	    --swift-out  "$(SHADER_BUNDLE)"
	touch $@

version: | swiftpm-pkg-config
	$(IN_BUILD_ENVIRONMENT) swift run --package-path $(PROJECT_ROOT) LumaVersionWriter $(PROJECT_ROOT) "$(VERSION_SOURCE)"

swiftpm-pkg-config: $(PHARO_VM) | $(GENERATED_DIR)
	Scripts/stage-pkg-config-for-swiftpm.sh $(SWIFTPM_PKG_CONFIG_DIR)

$(GENERATED_DIR):
	mkdir -p $@

soak: build
	LUMA_SOAK=$(LUMA_SOAK) LUMA_SOAK_SECONDS=$(or $(SECONDS),180) \
	    .build/debug/LumaGtk

render-tests: build
	LUMA_RENDER_TESTS=$(CURDIR)/build/render-tests .build/debug/LumaGtk

# A .pc carries no rpath -- SwiftPM rejects one -- so a VM built here has to be
# named on the link line to be found again at run time.
PHARO_VM_RPATH := $(if $(PHARO_VM),-Xlinker -rpath -Xlinker $(PHARO_VM_PREFIX)/lib)

build: bundle $(PHARO_IMAGE) $(PHARO_VM) | swiftpm-pkg-config
	$(IN_BUILD_ENVIRONMENT) swift build $(SWIFT_BUILD_FLAGS) $(PHARO_VM_RPATH)

ifneq ($(PHARO_VM_PC),)
# Resolving first is what puts the script on disk, and resolving does not need
# the VM that the script goes on to build.
$(PHARO_VM_PC): | $(GENERATED_DIR)
	@if [ -d "$(PHARO_SOURCE)/tools" ]; then \
	    tools="$(PHARO_SOURCE)"; \
	else \
	    $(IN_BUILD_ENVIRONMENT) swift package resolve; \
	    tools="$(CURDIR)/.build/checkouts/SwiftyPharo"; \
	fi; \
	echo "Building the Pharo VM into $(PHARO_VM_PREFIX)"; \
	DESTDIR= PREFIX="$(PHARO_VM_PREFIX)" PLATFORM=$(PHARO_VM_PLATFORM) "$$tools/tools/build-vm.sh"
endif

$(PHARO_IMAGE):
	$(PROJECT_ROOT)/Scripts/stage-pharo-image.sh

ifeq ($(shell uname -s),Darwin)
# macOS hands activation to the process that launched an unbundled binary, so
# the window can be clicked but never keeps keyboard focus. Run the same
# executable from inside a bundle, which keeps stdio on the terminal.
APP_BUNDLE := .build/Luma.app

run: build $(APP_BUNDLE)
	$(APP_BUNDLE)/Contents/MacOS/Luma

$(APP_BUNDLE): Data/macos/Info.plist
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	cp Data/macos/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	ln -sf $(CURDIR)/.build/debug/LumaGtk $(APP_BUNDLE)/Contents/MacOS/Luma
else
run: build
	./.build/debug/LumaGtk
endif

screenshots: build
	mkdir -p screenshots
	Scripts/capture-screenshots.sh screenshots

PREFIX ?= /usr/local
BINDIR := $(PREFIX)/bin
DATADIR := $(PREFIX)/share

ICON_SIZES := 32 48 64 128 256 512

install: build
	install -Dm755 .build/debug/LumaGtk $(DESTDIR)$(BINDIR)/luma
	install -Dm644 Data/re.frida.Luma.desktop $(DESTDIR)$(DATADIR)/applications/re.frida.Luma.desktop
	install -Dm644 Data/re.frida.Luma.xml $(DESTDIR)$(DATADIR)/mime/packages/re.frida.Luma.xml
	for size in $(ICON_SIZES); do \
	    install -Dm644 Data/icons/hicolor/$${size}x$${size}/apps/re.frida.Luma.png \
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
