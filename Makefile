BUILD_DIR   := $(PWD)/build
DERIVED_DIR := $(BUILD_DIR)/.derived
APP         := $(BUILD_DIR)/Luma.app

SOURCES := $(shell find Luma Sources Agent -type f \( \
    -name '*.swift' -o \
    -name '*.ts' -o \
    -name '*.plist' -o \
    -name '*.xcassets' -o \
    -name '*.pem' \
\) 2>/dev/null)

SHADER_SOURCES := $(wildcard Shaders/*.frag.glsl)

# Xcode stages the image from a script phase, which a SwiftPM build never runs.
PHARO_RELEASE := vm-20260811.3
PHARO_IMAGE_DIR := Sources/LumaCore/Resources/pharo-image
PHARO_IMAGE := $(PHARO_IMAGE_DIR)/SwiftyPharo.image
PHARO_LOCAL := $(PWD)/../SwiftyPharo/artifacts/SwiftyPharo.image
PHARO_CACHE := build/.pharo/$(PHARO_RELEASE)

LOCAL_SHADER_TOOLCHAIN := artifacts/ShaderToolchain.xcframework
ifneq ($(wildcard $(LOCAL_SHADER_TOOLCHAIN)),)
export SHADER_TOOLCHAIN_ROOT := $(LOCAL_SHADER_TOOLCHAIN)
endif

all: $(APP)

# The examples are Smalltalk in Swift string literals, which nothing else
# reads. This reads them the way the image would.
# A patch that has gone silent sounds fine to a compiler.
# Both build the agent bundle through a plugin, and SwiftPM runs those in a
# sandbox with no network for npm to install from.
check-patches: $(PHARO_IMAGE)
	swift run --disable-sandbox LumaSynthCheck

check-examples: $(PHARO_IMAGE)
	swift run --disable-sandbox LumaExampleCheck

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

$(APP): $(SOURCES) $(SHADER_SOURCES) Luma.xcodeproj Package.swift
	mkdir -p "$(BUILD_DIR)"
	xcodebuild \
		-project Luma.xcodeproj \
		-scheme AgentBundle \
		-configuration Release \
		-derivedDataPath "$(DERIVED_DIR)" \
		build
	xcodebuild \
		-project Luma.xcodeproj \
		-scheme Luma \
		-configuration Release \
		-derivedDataPath "$(DERIVED_DIR)" \
		CONFIGURATION_BUILD_DIR="$(BUILD_DIR)" \
		build
	@touch $@

gtk:
	$(MAKE) -C LumaGtk build

gtk-release:
	$(MAKE) -C LumaGtk build SWIFT_BUILD_FLAGS=-c\ release

clean:
	rm -rf "$(BUILD_DIR)"
	rm -rf .build LumaGtk/.build

.PHONY: all check-examples check-patches gtk gtk-release clean
