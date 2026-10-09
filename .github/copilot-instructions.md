# リポジトリ共通ルール（単体テスト関連）

このリポジトリは C++（Visual Studio 2022 / MSVC / .vcxproj）で、単体テストは Google Test / gMock を使う。
既存コードへのテスト追加は「AI が書き、スクリプトが検証して落とし、人間が最終承認する」方式で行う。

## 単体テストを書く・直すときの絶対ルール

1. **本番コード（`src/`, `include/` など config の `paths.production`）を変更しない。**
   テストのために依存を断つ必要がある場合（シーム導入）は、変更案を `test-reports/<対象>/analysis.md` に書いて人間の承認を待つ。
2. **既存テストを削除・改名・弱体化しない。** 追加のみ行う。
3. **テストを通すためにアサーションを実装に合わせて書き換えない。**
   仕様（コメント・ドキュメント・関数名・呼び出し元の使い方）と実装が食い違う場合は、
   仕様どおりの期待値でテストを書き、名前に `DISABLED_` を付け、`test-reports/bug_suspects.md` に記録して人間に報告する。
4. **合否はスクリプトが決める。** 作業の最後には必ず `.github/skills/cpp-test-gate/scripts/gate.ps1` を実行し、その判定（PASS/FAIL）と理由をそのまま報告する。自分の判断で「問題ない」と結論づけない。
5. 非決定的な要素（現在時刻、乱数、sleep、実行順序、未初期化メモリ、共有グローバル状態、実ファイル/ネットワーク）に依存しない。
6. `.github/` 配下（スキル、エージェント、フック、設定）と `test-reports/` のスクリプト生成物（baseline, gate, mutants の results/killers）は編集しない。

## テストの種類（必ず区別する）

- **仕様テスト**（`<Class>Test` スイート）: 期待値の根拠が仕様にあるもの。根拠をテスト直前のコメントに 1 行で書く（例: `// 仕様: Parser.h のコメント「空文字列は nullopt を返す」`）。
- **特性テスト**（`<Class>CharacterizationTest` スイート）: 仕様が不明で、現在の挙動を記録するだけのもの（Feathers の characterization test）。正しさは保証しない。
- **バグ疑い**: `DISABLED_` 付きの仕様テスト + `test-reports/bug_suspects.md` の記録。

詳細な書き方は `.github/instructions/gtest.instructions.md`、手順はスキル `cpp-test-gate` / `cpp-mutation` / `cpp-legacy-seams` を参照。
