[English](README.md) | 日本語

# DesktopTitle

デスクトップ (Space) を切り替えたときにデスクトップ名をオーバーレイ表示する macOS メニューバーアプリ。

## 機能

- デスクトップ切り替え時に各 Space の名前をオーバーレイ表示 (表示までの遅延と表示時間を設定可能)
- オーバーレイ外観のカスタマイズ: フォント / サイズ / 位置 (X/Y) / 統一カラー or デスクトップごとの色 / Space インデックスの表示有無
- **ディスプレイ構成ごとのプロファイル**: ディスプレイ構成 (例: 内蔵のみ、内蔵 + 外部) ごとに設定が保存される。マルチディスプレイ構成では内蔵ディスプレイのプロファイルを継承するか、独立した設定を使うかを選べる
- ログイン時の自動起動 (`SMAppService` 利用)
- フルスクリーン Space でのオーバーレイ表示の ON/OFF
- 軽量なメニューバー常駐アプリ (`LSUIElement`)

## 動作環境

- macOS 15.0 (Sequoia) 以降

## インストール

1. [Releases ページ](../../releases) から最新の `DesktopTitle-vX.Y.Z.zip` をダウンロードする。
2. zip を展開して `DesktopTitle.app` を `/Applications` に移動する。
3. **重要 — 起動前に quarantine 属性を削除してください。** リリースバイナリは **Apple Developer ID で署名されていません** (プロジェクトが Developer ID を保有していないため)。そのため macOS Gatekeeper が起動を拒否します。ターミナルで以下を一度だけ実行してください:

   ```bash
   xattr -dr com.apple.quarantine /Applications/DesktopTitle.app
   ```

   実行後は Finder / Spotlight / Dock から通常通り起動できます。

   <details><summary>このコマンドが必要な理由</summary>

   ブラウザ経由でダウンロードされたファイルには `com.apple.quarantine` 拡張属性が付きます。Gatekeeper はこの属性を見て、Developer ID Application 証明書による署名や Apple による公証 (notarization) がない第三者アプリの起動をブロックします。本プロジェクトは Developer ID を保有していないため、Release ワークフローは `CODE_SIGNING_ALLOWED=NO` でビルドしており、生成される `.app` には ad-hoc 署名しか付いていません。`xattr -dr com.apple.quarantine` を実行すると、Gatekeeper はこのアプリの署名チェックをスキップするようになり、通常通り起動できます。

   </details>

## 使い方

アプリはメニューバーに常駐します。

1. `DesktopTitle.app` を起動する。メニューバーにアイコンが表示されます。
2. アイコンをクリックして **Settings…** を選び、設定ウィンドウを開きます。
3. **Desktops** タブ — 各デスクトップ (Space) に名前を設定します。マルチディスプレイ環境ではデスクトップごとに所属スクリーン名が表示され、構成間で共有されているデスクトップは `(shared)` と表示されます。
4. **Display** タブ — フォント、サイズ、表示位置、色、表示時間、遅延、Space インデックス表示の ON/OFF を調整します。
5. **General** タブ — **Launch at login** (ログイン時の自動起動) と **Show for fullscreen apps** (フルスクリーン時のオーバーレイ、デフォルトOFF) を切り替え、現在のディスプレイ構成のプロファイルモードを管理し、必要に応じて **Reset Current Profile to Defaults** で初期化します。
6. デスクトップを切り替えるとオーバーレイが表示されます。

### ディスプレイ構成ごとのプロファイル

設定 (オーバーレイ外観、デスクトップ名) は **ディスプレイ構成単位** で保存されます。グローバルではありません。モニターを接続/切断するとアプリは該当する構成のプロファイルを自動で読み込みます。マルチディスプレイ構成では2つのモードがあります:

- **Inherit (継承)** — シングルディスプレイのベースプロファイルが既に存在する場合のデフォルト。マルチディスプレイ構成は内蔵ディスプレイのプロファイルをミラーします。変更は両方向に伝播します。
- **Independent (独立)** — マルチディスプレイ構成が独自の設定を持ちます。外部モニター接続時に異なるレイアウトを使いたい場合に便利です。

モードは **General** タブで切り替えられます。

## ビルド

### 必要なもの

- Xcode 16.0 以降
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`project.yml` から Xcode プロジェクトを生成)

### ビルド手順

1. Xcode プロジェクトを生成:
   ```bash
   xcodegen generate
   ```

2. コマンドラインからビルド:
   ```bash
   xcodebuild -project DesktopTitle.xcodeproj -scheme DesktopTitle -configuration Debug -derivedDataPath ./build build
   ```

3. アプリを起動:
   ```bash
   open ./build/Build/Products/Debug/DesktopTitle.app
   ```

または `DesktopTitle.xcodeproj` を Xcode で開いてビルドします。

## プロジェクト構成

```
DesktopTitle/
├── App/
│   ├── DesktopTitleApp.swift     # SwiftUI アプリのエントリポイント
│   └── AppDelegate.swift         # NSApplicationDelegate、ライフサイクル
├── Core/
│   ├── CGSPrivate.h              # CoreGraphics Space 関連の private API
│   ├── SpaceIdentifier.swift     # Space ID の安定取得
│   ├── SpaceMonitor.swift        # アクティブ Space 変更の監視
│   ├── DisplayConfiguration.swift# ディスプレイ構成 + プロファイル ID
│   └── DebugLog.swift            # 条件付きファイル/コンソールログ
├── Models/
│   ├── SpaceConfig.swift         # Space ごとの設定 (名前、色)
│   └── AppSettings.swift         # ディスプレイ構成プロファイル + グローバル設定
├── UI/
│   ├── MenuBarController.swift   # メニューバーアイテム + 設定ウィンドウ
│   ├── OverlayWindow.swift       # ボーダーレス透過 NSWindow
│   ├── OverlayView.swift         # オーバーレイの SwiftUI ビュー
│   └── SettingsView.swift        # 設定ウィンドウ UI (3タブ)
└── DesktopTitle-Bridging-Header.h
```

## リリース

リリースは [Release ワークフロー](.github/workflows/release.yml) が `v*` タグの push 時に自動で行います。タグはバージョンバンプ済みの commit を指している必要があります。そうでないと公開される `.app` がリリース名と一致しません。

```bash
# 1. project.yml の CFBundleShortVersionString と CHANGELOG.md を更新し、プロジェクトを再生成
xcodegen generate

# 2. バージョンバンプを default branch にコミット & push
git add project.yml DesktopTitle.xcodeproj
git commit -m "Bump version to 1.2.3"
git push

# 3. その commit に annotated tag を打って push
git tag -a v1.2.3 -m "v1.2.3"
git push origin v1.2.3
```

ワークフローは `xcodebuild -configuration Release` で Release ビルドを行い、`ditto` で `DesktopTitle.app` を zip に固め、`DesktopTitle-vX.Y.Z.zip` を新しい GitHub Release に自動生成のリリースノート付きで公開します。

ビルドは未署名です (Apple Developer ID なし)。エンドユーザは初回起動時に [インストール](#インストール) の手順で Gatekeeper を回避する必要があります。

## ライセンス

MIT License
