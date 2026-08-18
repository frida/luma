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

PHARO_IMAGE := Sources/LumaCore/Resources/pharo-image/SwiftyPharo.image

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
	scripts/stage-pharo-image.sh

$(APP): $(SOURCES) $(SHADER_SOURCES) Luma.xcodeproj Package.swift
	mkdir -p "$(BUILD_DIR)"
	scripts/generate-sources.sh
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
