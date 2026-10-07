# OpenWrt 用 gatus .apk ビルドのショートカット。
#
#   make apk
#   make apk TARGET=mediatek/mt7622 ARCH=aarch64_cortex-a53 RELEASE=25.12.4
#   make clean

TARGET  ?= mediatek/mt7622
ARCH    ?= aarch64_cortex-a53
RELEASE ?= 25.12.4
OUT_DIR ?= dist

.PHONY: apk setup clean

apk:
	./scripts/build-apk.sh --target "$(TARGET)" --arch "$(ARCH)" --release "$(RELEASE)" --upx --output "$(OUT_DIR)"

# サブモジュールを取得する（初回のみ）
setup:
	git submodule update --init --recursive

clean:
	rm -rf dist .cache
