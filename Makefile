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
GENERATED_METAL_DIR := $(PWD)/Luma/Shaders/Generated

all: $(APP)

$(APP): $(SOURCES) $(SHADER_SOURCES) Luma.xcodeproj Package.swift
	mkdir -p "$(BUILD_DIR)"
	swift run luma-shader-compiler \
		--shader-dir "$(PWD)/Shaders" \
		--metal-dir  "$(GENERATED_METAL_DIR)" \
		--header-dir "$(PWD)/LumaGtk/Sources/CLuma/generated"
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
