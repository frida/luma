.PHONY: build run clean bundle screenshots install uninstall

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

PHARO_RELEASE := vm-20260802.8
PHARO_IMAGE_DIR := Sources/LumaGtk/Resources/pharo-image
PHARO_IMAGE := $(PHARO_IMAGE_DIR)/SwiftyPharo.image
PHARO_LOCAL := $(PROJECT_ROOT)/../SwiftyPharo/artifacts/SwiftyPharo.image
PHARO_CACHE := .build/.pharo/$(PHARO_RELEASE)

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

build: bundle $(PHARO_IMAGE)
	swift build $(SWIFT_BUILD_FLAGS)

$(PHARO_IMAGE):
	@mkdir -p $(PHARO_IMAGE_DIR)
	@if [ -f "$(PHARO_LOCAL)" ]; then \
	    src="$(PHARO_LOCAL)"; \
	elif [ -f "$(PHARO_CACHE)/SwiftyPharo.image" ]; then \
	    src="$(PHARO_CACHE)/SwiftyPharo.image"; \
	else \
	    echo "Fetching Pharo image $(PHARO_RELEASE)"; \
	    mkdir -p "$(PHARO_CACHE)"; \
	    curl -sSL "https://github.com/frida/SwiftyPharo/releases/download/$(PHARO_RELEASE)/SwiftyPharo.image.zip" -o "$(PHARO_CACHE)/image.zip"; \
	    unzip -qo "$(PHARO_CACHE)/image.zip" -d "$(PHARO_CACHE)"; \
	    src="$(PHARO_CACHE)/SwiftyPharo.image"; \
	fi; \
	cp "$$src" "$(PHARO_IMAGE)"; \
	cp "$${src%.image}.changes" "$(PHARO_IMAGE_DIR)/SwiftyPharo.changes"

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
