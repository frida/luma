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

# A locally made toolchain short-circuits the published artifact.
LOCAL_SHADER_TOOLCHAIN := artifacts/ShaderToolchain.xcframework
ifneq ($(wildcard $(LOCAL_SHADER_TOOLCHAIN)),)
export SHADER_TOOLCHAIN_ROOT := $(LOCAL_SHADER_TOOLCHAIN)
endif

all: $(APP)

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

.PHONY: all gtk gtk-release clean
