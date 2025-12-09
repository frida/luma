BUILD_DIR   := $(PWD)/build
DERIVED_DIR := $(BUILD_DIR)/.derived
APP         := $(BUILD_DIR)/Luma.app

SOURCES := $(shell find Luma -type f \( \
    -name '*.swift' -o \
    -name '*.ts' -o \
    -name '*.plist' -o \
    -name '*.xcassets' -o \
    -name '*.pem' \
\))

all: $(APP)

$(APP): $(SOURCES) Luma.xcodeproj
	mkdir -p "$(BUILD_DIR)"
	xcodebuild \
		-project Luma.xcodeproj \
		-scheme Luma \
		-configuration Release \
		-derivedDataPath "$(DERIVED_DIR)" \
		CONFIGURATION_BUILD_DIR="$(BUILD_DIR)" \
		build
	@touch $@

clean:
	rm -rf "$(BUILD_DIR)"

.PHONY: all clean
