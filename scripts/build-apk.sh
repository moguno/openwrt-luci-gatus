#!/usr/bin/env bash
#
# build-apk.sh — OpenWrt 用 gatus の .apk パッケージをビルドする。
#
# OpenWrt 24.10 以降の apk-tools 3 は v3 (ADB) 形式のパッケージを使う。
# そのため「control + data の連結 gzip」ではインストールできない。
# このスクリプトは次の手順で正しい apk を作る:
#
#   1. gatus サブモジュールを Go でクロスコンパイル (CGO 無効、任意で UPX)
#   2. 対象ターゲットの OpenWrt SDK を取得・展開
#   3. SDK 同梱の host 版 `apk mkpkg` で v3 apk を生成
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SRC_DIR="${GATUS_SRC:-$REPO_ROOT/gatus}"
OPENWRT_DIR="${OPENWRT_DIR:-$REPO_ROOT/openwrt}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/dist}"
SDK_CACHE="${SDK_CACHE:-$REPO_ROOT/.cache/sdk}"

# 既定は実機 (mediatek/mt7622) 向け
OWRT_RELEASE="${OWRT_RELEASE:-25.12.4}"
OWRT_TARGET="${OWRT_TARGET:-mediatek/mt7622}"
OWRT_ARCH="${OWRT_ARCH:-aarch64_cortex-a53}"
PKG_NAME="gatus"
PKG_RELEASE="${PKG_RELEASE:-1}"
GATUS_VERSION="${GATUS_VERSION:-}"
USE_UPX=0
SIGN_KEY=""
WITH_LUCI=1

# OpenWrt アーキ名 -> Go のクロスコンパイル設定
declare -A GOARCH_OF=(
  [x86_64]=amd64
  [i386_pentium4]=386
  [aarch64_cortex-a53]=arm64
  [aarch64_generic]=arm64
  [arm_cortex-a7]=arm
  [arm_cortex-a9]=arm
  [mipsel_24kc]=mipsle
  [mipsel_74kc]=mipsle
  [mips_24kc]=mips
  [riscv64]=riscv64
)
declare -A GOARM_OF=(
  [arm_cortex-a7]=7
  [arm_cortex-a9]=7
)
declare -A GOMIPS_OF=(
  [mipsel_24kc]=softfloat
  [mipsel_74kc]=softfloat
  [mips_24kc]=softfloat
)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage: build-apk.sh [options]

Options:
  -t, --target <t>      OpenWrt ターゲット 例: mediatek/mt7622 (既定)
      --arch <a>        apk アーキ名 例: aarch64_cortex-a53 (既定)
      --release <r>     OpenWrt リリース 例: 25.12.4 (既定)
  -u, --upx             バイナリを UPX で圧縮（スリム化）
      --no-luci         LuCI プラグイン (luci-app-gatus) をビルドしない
  -o, --output <dir>    出力ディレクトリ（既定: ./dist）
      --version <ver>   gatus バージョン（既定: サブモジュールから自動判定）
      --pkg-release <n> パッケージリリース番号（既定: 1）
      --sign-key <file> 秘密鍵で署名する場合の鍵ファイル
      --sdk-cache <dir> SDK のキャッシュ先（既定: ./.cache/sdk）
  -h, --help            このヘルプを表示
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--target)      OWRT_TARGET="$2"; shift 2 ;;
    --arch)           OWRT_ARCH="$2"; shift 2 ;;
    --release)        OWRT_RELEASE="$2"; shift 2 ;;
    -u|--upx)         USE_UPX=1; shift ;;
    --no-luci)        WITH_LUCI=0; shift ;;
    -o|--output)      OUT_DIR="$2"; shift 2 ;;
    --version)        GATUS_VERSION="$2"; shift 2 ;;
    --pkg-release)    PKG_RELEASE="$2"; shift 2 ;;
    --sign-key)       SIGN_KEY="$2"; shift 2 ;;
    --sdk-cache)      SDK_CACHE="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *)                die "unknown option: $1 (try --help)" ;;
  esac
done

[ -n "${GOARCH_OF[$OWRT_ARCH]:-}" ] || die "unknown arch: $OWRT_ARCH (try --help)"
GOARCH="${GOARCH_OF[$OWRT_ARCH]}"
GOARM="${GOARM_OF[$OWRT_ARCH]:-}"
GOMIPS="${GOMIPS_OF[$OWRT_ARCH]:-}"

resolve_version() {
  if [ -z "$GATUS_VERSION" ] && git -C "$SRC_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    local v
    v="$(git -C "$SRC_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
    [ -n "$v" ] || v="$(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null || true)"
    GATUS_VERSION="${v#v}"
  fi
  [ -n "$GATUS_VERSION" ] || GATUS_VERSION="0.0.0"
}

fetch_sdk() {
  local base="openwrt-sdk-${OWRT_RELEASE}-${OWRT_TARGET//\//-}"
  local existing
  existing="$(ls -d "$SDK_CACHE"/${base}* 2>/dev/null | head -1 || true)"
  if [ -n "$existing" ] && [ -x "$existing/staging_dir/host/bin/apk" ]; then
    echo "$existing"; return
  fi

  mkdir -p "$SDK_CACHE"
  local index url file
  index="https://downloads.openwrt.org/releases/${OWRT_RELEASE}/targets/${OWRT_TARGET}/"
  log "SDK を探しています: $index"
  file="$(curl -fsSL "$index" | grep -oE "openwrt-sdk-${OWRT_RELEASE}-[^\"<>]*\.tar\.zst" | head -1 || true)"
  [ -n "$file" ] || die "SDK が見つかりません: $index"
  url="${index}${file}"

  if [ ! -f "$SDK_CACHE/$file" ]; then
    log "SDK をダウンロード: $file"
    curl -fSL -o "$SDK_CACHE/$file" "$url"
  fi
  log "SDK を展開しています ..."
  tar --zstd -xf "$SDK_CACHE/$file" -C "$SDK_CACHE" 2>/dev/null || \
    tar --zstd -xf "$SDK_CACHE/$file" -C "$SDK_CACHE"
  existing="$(ls -d "$SDK_CACHE"/${base}* 2>/dev/null | grep -v '\.tar\.zst$' | head -1 || true)"
  [ -n "$existing" ] || die "SDK の展開に失敗しました"
  echo "$existing"
}

build_binary() {
  local out="$1"
  local extra=""
  [ -n "$GOARM" ]  && extra="$extra GOARM=$GOARM"
  [ -n "$GOMIPS" ] && extra="$extra GOMIPS=$GOMIPS"
  log "gatus をコンパイル (GOARCH=$GOARCH$extra) ..."
  (
    cd "$SRC_DIR"
    # shellcheck disable=SC2086
    env CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH" $extra \
      go build -trimpath -buildvcs=false \
        -ldflags "-s -w" -o "$out" .
  )
  if [ "$USE_UPX" -eq 1 ]; then
    command -v upx >/dev/null 2>&1 || die "--upx を指定しましたが upx が見つかりません"
    log "UPX で圧縮しています ..."
    upx --best --lzma -q "$out" 2>/dev/null || upx --best -q "$out" 2>/dev/null \
      || warn "UPX 圧縮に失敗。非圧縮のまま続行します"
  fi
}

make_apk() {
  local sdk="$1" bin="$2"
  local apkbin="$sdk/staging_dir/host/bin/apk"
  [ -x "$apkbin" ] || die "SDK の apk が見つかりません: $apkbin"

  local stage
  stage="$(mktemp -d "${TMPDIR:-/tmp}/gatus-stage.XXXXXX")"
  install -D -m0755 "$bin"                        "$stage/usr/bin/$PKG_NAME"
  install -D -m0755 "$OPENWRT_DIR/gatus.init"     "$stage/etc/init.d/$PKG_NAME"
  install -D -m0644 "$OPENWRT_DIR/gatus.config"   "$stage/etc/config/$PKG_NAME"
  install -D -m0644 "$OPENWRT_DIR/config.yaml"    "$stage/etc/gatus/config.yaml"

  local pkgver="${GATUS_VERSION}-r${PKG_RELEASE}"
  local out="$OUT_DIR/${PKG_NAME}-${pkgver}_${OWRT_ARCH}.apk"
  local sign=()
  [ -n "$SIGN_KEY" ] && sign=(--sign-key "$SIGN_KEY")

  log "apk を生成しています (arch=$OWRT_ARCH) ..."
  "$apkbin" mkpkg \
    --info "name:$PKG_NAME" \
    --info "version:$pkgver" \
    --info "description:Gatus is an automated status page / health dashboard" \
    --info "arch:$OWRT_ARCH" \
    --info "license:Apache-2.0" \
    --info "origin:$PKG_NAME" \
    --info "url:https://github.com/TwiN/gatus" \
    --info "depends:ca-bundle" \
    "${sign[@]}" \
    --files "$stage" \
    --output "$out"
  rm -rf "$stage"
  log "wrote $(basename "$out") ($(du -h "$out" | awk '{print $1}'))"
}

make_luci_apk() {
  local sdk="$1"
  local apkbin="$sdk/staging_dir/host/bin/apk"
  local src="$OPENWRT_DIR/luci-app-gatus"
  [ -d "$src" ] || { warn "LuCI プラグインのソースがありません: $src"; return 0; }

  local stage
  stage="$(mktemp -d "${TMPDIR:-/tmp}/gatus-luci.XXXXXX")"
  if [ -d "$src/htdocs" ]; then mkdir -p "$stage/www"; cp -a "$src/htdocs/." "$stage/www/"; fi
  if [ -d "$src/root" ];   then cp -a "$src/root/." "$stage/"; fi

  local name="luci-app-gatus"
  local pkgver="${GATUS_VERSION}-r${PKG_RELEASE}"
  local out="$OUT_DIR/${name}-${pkgver}.apk"
  local sign=()
  [ -n "$SIGN_KEY" ] && sign=(--sign-key "$SIGN_KEY")

  log "LuCI プラグイン apk を生成しています (arch=noarch) ..."
  "$apkbin" mkpkg \
    --info "name:$name" \
    --info "version:$pkgver" \
    --info "description:LuCI app to edit the Gatus configuration (config.yaml)" \
    --info "arch:noarch" \
    --info "license:Apache-2.0" \
    --info "origin:$name" \
    --info "url:https://github.com/TwiN/gatus" \
    --info "depends:luci-base" \
    "${sign[@]}" \
    --files "$stage" \
    --output "$out"
  rm -rf "$stage"
  log "wrote $(basename "$out") ($(du -h "$out" | awk '{print $1}'))"
}

command -v go >/dev/null 2>&1 || die "go が見つかりません"
command -v curl >/dev/null 2>&1 || die "curl が見つかりません"
[ -f "$SRC_DIR/go.mod" ] || die "gatus のソースがありません: $SRC_DIR (git submodule update --init)"
[ -f "$OPENWRT_DIR/gatus.init" ] || die "パッケージ用ファイルがありません: $OPENWRT_DIR"

mkdir -p "$OUT_DIR" "$SDK_CACHE"
resolve_version
log "gatus version: $GATUS_VERSION, package: ${GATUS_VERSION}-r${PKG_RELEASE}, target: $OWRT_TARGET, arch: $OWRT_ARCH"

work="$(mktemp -d "${TMPDIR:-/tmp}/gatus-build.XXXXXX")"
trap 'rm -rf "$work"' EXIT

build_binary "$work/gatus"
SDK="$(fetch_sdk)"
make_apk "$SDK" "$work/gatus"
[ "$WITH_LUCI" -eq 1 ] && make_luci_apk "$SDK"

log "完了。パッケージ: $OUT_DIR"
