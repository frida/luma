.PHONY: build run clean

PKG_CONFIG_PATH ?= /usr/local/lib64/pkgconfig
LD_LIBRARY_PATH ?= /usr/local/lib

export PKG_CONFIG_PATH

build:
	swift build

run: build
	LD_LIBRARY_PATH=$(LD_LIBRARY_PATH) ./.build/debug/LumaGtk

clean:
	swift package clean
	rm -rf .build
