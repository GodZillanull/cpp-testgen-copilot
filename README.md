# cpp-testgen-copilot

VS Code の GitHub Copilot で、既存の C++ コード（Visual Studio 2022 / MSVC / .vcxproj）に Google Test の単体テストを追加するための設定一式です。

方針は「AI が書き、スクリプトが検証して落とし、人間が最終承認する」。仕様書のないレガシーコードを前提に、AI は現在の動作を特性テストで固定し、推測した仕様は〇×で答えられる質問リストにして人間に確認します。Meta の TestGen-LLM（検証フィルタ付きテスト生成）と ACH（ミューテーション誘導のテスト生成）、Google のミューテーションテスト運用、CoverUp（カバレッジ誘導）、Feathers のレガシーコード手法をもとにしています。

## 中身

| パス | 役割 |
|---|---|
| `.github/copilot-instructions.md` | 常時適用ルール |
| `.github/instructions/gtest.instructions.md` | Google Test 記述規約（tests/ 配下に適用） |
| `.github/agents/` | `test-writer`（作成、フックで制限）と `test-reviewer`（読み取り専用レビュー） |
| `.github/prompts/` | `/tg-0-setup` 〜 `/tg-6-answers` |
| `.github/skills/` | `cpp-test-gate`（ベースライン・カバレッジ・合否判定）、`cpp-mutation`（ミューテーション）、`cpp-legacy-seams`（依存の切り離し） |
| `.github/testgen/` | 設定 `config.json` とフック |
| `.vscode/settings.json` | Copilot 側の設定 |

## 導入

1. このリポジトリの `.github/`, `.vscode/`, `test-reports/`, `TESTGEN_README.md` を、テストを追加したい C++ リポジトリのルートにコピーします。
2. （任意）[OpenCppCoverage](https://github.com/OpenCppCoverage/OpenCppCoverage/releases) をインストールします。入れなければ、追加インストール不要の**ミューテーション専用モード**で動きます（新規テストは「既存テストが見逃す擬似バグを検出した」場合だけ採用）。
3. `.github/testgen/config.json` を自分のソリューションに合わせます。
4. VS Code の Copilot Chat で `/tg-0-setup` を実行します。

詳細は [TESTGEN_README.md](TESTGEN_README.md) を参照してください。
