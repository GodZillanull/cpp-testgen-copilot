---
name: cpp-legacy-seams
description: How to get untestable legacy C++ (singletons, globals, statics, time, file/network/hardware access, hard-coded new) under Google Test using Michael Feathers' seams, and how to write a seam proposal for human approval. Use when a class cannot be tested through its public API without touching production code.
---

# レガシー C++ をテスト可能にする（Feathers のシーム）

出典: Michael Feathers『Working Effectively with Legacy Code』。テストのための変更は最小限にし、**オブジェクトシームをリンク/プリプロセッサシームより優先**する。

このリポジトリでは**本番コードの変更は人間の承認が必要**。あなたはシームを提案するだけで、承認（`.github/testgen/seam-approved` の作成）があるまで本番コードを編集しない（フックで拒否される）。

## まず確認すること（変更なしで済まないか）

1. 公開 API と本物の依存だけでテストできないか（Google は本物の依存を優先する）。
2. 依存先がすでに interface / 仮想関数 / テンプレート引数 / コールバックで差し替え可能になっていないか。
3. 時刻・ファイルなどが、テスト環境でも安全かつ決定的に動かせないか（一時ディレクトリなど）。

これで足りるなら、シームは不要。テストを書く。

## シームの選択肢（推奨順）

| 状況 | 手法 | 変更量 |
|---|---|---|
| コンストラクタ内で `new Foo` / メンバとして具象型を保持 | **インターフェース抽出 + コンストラクタ注入**（既存コンストラクタは残し、注入用を追加） | 小 |
| 1 つのメソッド内で外部 I/O を呼ぶ | **Subclass and Override**: その呼び出しを `protected virtual` メソッドに切り出し、テストでサブクラス化 | 小 |
| シングルトン / グローバル関数（`Config::Instance()`, `GetTickCount()`） | **ラッパー＋差し替え口**: 取得処理を関数オブジェクトや interface 経由にし、既定値は従来の実装 | 小〜中 |
| ヘッダオンリー / 性能上 virtual を避けたい | **テンプレートシーム**: 依存型をテンプレート引数にし、既定引数で従来型 | 中 |
| 変更がどうしても許されない | **リンクシーム**: テスト用 .vcxproj では本番の .cpp の代わりにフェイク実装の .cpp をリンクする | 本番変更なし（ビルド構成のみ） |
| 最後の手段 | プリプロセッサシーム（`#ifdef UNIT_TEST`） | 非推奨 |

時刻・乱数・ファイルシステム・環境変数は「Clock」「Random」「FileSystem」のような小さなインターフェースに集約すると、以降のテストがすべて楽になる。

### 例: コンストラクタ注入（既存の呼び出し元は無変更）

```cpp
// 変更前
class Uploader {
public:
    Uploader() : client_(std::make_unique<HttpClient>()) {}
private:
    std::unique_ptr<HttpClient> client_;
};

// 変更後（提案）
class IHttpClient { public: virtual ~IHttpClient() = default; virtual Response Post(const Request&) = 0; };
class HttpClient : public IHttpClient { /* 既存実装 */ };

class Uploader {
public:
    Uploader() : Uploader(std::make_unique<HttpClient>()) {}               // 既存の呼び出し元はこのまま
    explicit Uploader(std::unique_ptr<IHttpClient> c) : client_(std::move(c)) {}  // テスト用
private:
    std::unique_ptr<IHttpClient> client_;
};
```

## 提案の書き方（`test-reports/<対象>/analysis.md` の「シーム提案」節）

各提案に以下を書く。人間はこれを見て承認・却下する。

- **対象**: ファイルとクラス/関数
- **阻害要因**: 何がテストを妨げているか（例: コンストラクタで実 DB に接続する）
- **手法**: 上表のどれか
- **差分の概要**: 追加/変更するシグネチャ（数行のコード）
- **既存の呼び出し元への影響**: 無変更で済むか。ABI/性能への影響
- **これで書けるようになるテスト**: 2〜3 件の例

承認後の作業順: (1) シームだけを入れる → (2) `gate.ps1` で既存テストが壊れていないことを確認（本番変更は承認済みとして許可される）→ (3) テストを追加。シーム導入とロジック変更を混ぜない。
