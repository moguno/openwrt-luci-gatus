# gatus for OpenWrt

[gatus](https://github.com/TwiN/gatus) の OpenWrt 用 `.apk` をビルドするリポジトリです。
gatus 本体は git サブモジュールとして取り込み、Go でクロスコンパイルし、OpenWrt SDK の
`apk mkpkg` で v3 (ADB) 形式の apk にパッケージします。UPX でバイナリをスリム化でき、
GitHub Actions で複数ターゲットの apk をまとめて生成できます。

## 背景: OpenWrt の apk は v3 (ADB) 形式

OpenWrt 24.10 以降の apk-tools 3 は **v3 (ADB) 形式**のパッケージを使います。
Alpine などで使われる v2 形式（`control.tar.gz` + `data.tar.gz` の連結 gzip）は
インストールできず `unexpected end of file` になります。そのため本リポジトリは
OpenWrt SDK 同梱の host 版 `apk mkpkg`（OpenWrt のビルドシステムが内部で使うものと同一）で
パッケージを生成します。

## ディレクトリ構成

```
.
├── .github/workflows/build-apk.yml   # GitHub Actions（apk を生成・リリース添付）
├── gatus/                            # git サブモジュール（TwiN/gatus のソース）
├── openwrt/
│   ├── gatus.init                    # procd 起動スクリプト -> /etc/init.d/gatus
│   ├── gatus.config                  # UCI 設定        -> /etc/config/gatus
│   ├── config.yaml                   # 既定の gatus 設定 -> /etc/gatus/config.yaml
│   └── luci-app-gatus/               # LuCI プラグイン（config.yaml を編集する UI）
├── scripts/build-apk.sh              # apk ビルドスクリプト
└── Makefile
```

## セットアップ

初回のみ、サブモジュールを取得します。

```sh
git submodule update --init --recursive
```

新規にこのリポジトリ構成を作る場合は:

```sh
git init
git submodule add https://github.com/TwiN/gatus.git gatus
```

## ローカルでビルド

必要なもの: Go ツールチェーン、`curl`、`zstd`、`tar`（任意で `upx`）。
初回は対象ターゲットの OpenWrt SDK（数百 MB）をダウンロードします。

```sh
# 既定: mediatek/mt7622, aarch64_cortex-a53, OpenWrt 25.12.4
make apk

# ターゲットを指定
make apk TARGET=mediatek/mt7622 ARCH=aarch64_cortex-a53 RELEASE=25.12.4

# スクリプトを直接使う
./scripts/build-apk.sh --target mediatek/mt7622 --arch aarch64_cortex-a53 --release 25.12.4 --upx
```

主なオプションは `./scripts/build-apk.sh --help` を参照してください。
ビルドすると次の 2 つの apk が生成されます（`--no-luci` で LuCI プラグインを除外）。

- `dist/gatus-<ver>-r1_<arch>.apk` — 本体（arch はターゲット依存。例: `gatus-5.37.0-r1_aarch64_cortex-a53.apk`）
- `dist/luci-app-gatus-<ver>-r1.apk` — LuCI プラグイン（arch: `noarch`）

> 補足: gatus の `go.mod` は新しい Go を要求することがあります（例: go 1.26）。
> 手元の Go が古い場合は `GOTOOLCHAIN=auto` を付けると自動でツールチェーンを取得します。

## GitHub Actions

`.github/workflows/build-apk.yml` が次を実行します。

- `push`（`v*` タグ）/ `pull_request` / 手動実行（`workflow_dispatch`）で起動
- ターゲットごとに apk をビルドし、Artifact としてアップロード
- タグ push 時は GitHub Release に apk を添付
- `workflow_dispatch` では `target` / `arch` / `release` を任意指定可能

マトリクス（既定）:

| target            | arch                 |
| ----------------- | -------------------- |
| `mediatek/mt7622` | `aarch64_cortex-a53` |
| `x86/64`          | `x86_64`             |

## OpenWrt へのインストール

生成した apk は未署名です。転送して次のようにインストールします。

```sh
scp -O dist/gatus-<ver>-r1_<arch>.apk dist/luci-app-gatus-<ver>-r1.apk root@<device>:/tmp/
ssh root@<device> 'apk add --allow-untrusted /tmp/gatus-<ver>-r1_<arch>.apk /tmp/luci-app-gatus-<ver>-r1.apk'
ssh root@<device> '/etc/init.d/gatus enable && /etc/init.d/gatus start'
```

## LuCI プラグイン（config.yaml を編集）

`luci-app-gatus` を入れると、LuCI の「サービス → Gatus」に設定ページが追加されます。
ページには `/etc/gatus/config.yaml` をそのまま編集できるマルチラインテキストボックスがあり、
「保存」で書き込み、「保存 & 適用」で書き込み後に gatus を再起動します。

構成（OpenWrt 標準の LuCI アプリ配置）:

| 同梱元 | インストール先 |
| --- | --- |
| `openwrt/luci-app-gatus/htdocs/.../view/gatus/config.js` | `/www/luci-static/resources/view/gatus/config.js` |
| `openwrt/luci-app-gatus/root/usr/share/luci/menu.d/luci-app-gatus.json` | `/usr/share/luci/menu.d/luci-app-gatus.json` |
| `openwrt/luci-app-gatus/root/usr/share/rpcd/acl.d/luci-app-gatus.json` | `/usr/share/rpcd/acl.d/luci-app-gatus.json` |

依存は `luci-base`（`rpcd-mod-file` 経由でファイル読み書き）です。

設定は `/etc/config/gatus`（有効化・設定ファイルパス）と `/etc/gatus/config.yaml`
（gatus 本体の設定）です。監視データは `/var/lib/gatus/` に保存されます。

例（実機: OpenWrt 25.12.4 / mediatek mt7622 / aarch64_cortex-a53）:

```sh
scp -O dist/gatus-5.37.0-r1_aarch64_cortex-a53.apk dist/luci-app-gatus-5.37.0-r1.apk root@192.168.0.5:/tmp/
ssh root@192.168.0.5 'apk add --allow-untrusted /tmp/gatus-5.37.0-r1_aarch64_cortex-a53.apk /tmp/luci-app-gatus-5.37.0-r1.apk \
  && /etc/init.d/gatus enable && /etc/init.d/gatus start'
```

## リリース（GitHub Releases に apk を添付）

`v*` 形式のタグを push すると `release` ジョブが動き、全ターゲットの apk を
GitHub Release の添付ファイルとして公開します。

```sh
git tag v5.37.0
git push origin v5.37.0
```

- 手動で試す場合は Actions の `Run workflow`（workflow_dispatch）でも apk を Artifact として取得できます。

### 収録物

- `/usr/bin/gatus` — 本体（Go 製スタティックバイナリ。UPX 圧縮可）
- `/etc/init.d/gatus` — procd 起動スクリプト
- `/etc/config/gatus` — UCI 設定
- `/etc/gatus/config.yaml` — 既定の gatus 設定

## 署名について（任意）

配布リポジトリとして `apk` に検証させたい場合は署名が必要です。
`scripts/build-apk.sh --sign-key <秘密鍵>` を指定すると `apk mkpkg --sign-key` で署名します
（公開鍵は `/etc/apk/keys/` に配置）。未署名の場合は `--allow-untrusted` を付けてください。

## 現在の制約

- 現状のパッケージは動作確認を優先しており、`/etc/config/gatus` と
  `/etc/gatus/config.yaml` を apk の conffile としてマークしていません。
  上書き更新を避けたい場合は conffile 対応を追加してください。
- SDK の host ツール（`apk`）を利用するため、対応ターゲットの SDK が必要です。
