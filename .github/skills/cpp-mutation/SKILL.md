---
name: cpp-mutation
description: Mutation testing for MSVC C++ code without Mull or any install - the agent proposes realistic single-line faults (mutants) in production code, a script applies each one, rebuilds, runs Google Test and restores the file. Use to find weak assertions and write tests that catch surviving faults (Meta ACH style), and as the main guide for what to test when no coverage tool is installed (mutation-only mode).
---

# LLM 提案型ミューテーションテスト（Meta ACH 方式）

カバレッジは「実行したか」しか測れない。ミューテーションは「バグを入れたらテストが気づくか」を測る。
Windows/MSVC では Mull が使えないため、**ミュータント（擬似バグ）はあなたが提案し、適用・ビルド・実行・復元はスクリプトが行う**。
スクリプトは各ミュータントの後で元ファイルをバイト単位で必ず復元する（中断時も次回起動時に自動復元）。

カバレッジツールが無い環境（ミューテーション専用モード）では、これが**テストの価値を測る唯一の基準**になる。
ゲートは新規テストを「ベースラインのどのテストも検出しないミュータントを検出した」場合にだけ合格させるので、**テストを書く前に**ミュータントを作って実行し、生き残りを確認しておく。

## 手順

1. 対象ファイルを読み、`test-reports/mutants/mutants.json` を作成する（形式は下記）。10〜20 個。
2. 実行: `powershell -NoProfile -ExecutionPolicy Bypass -File .github/skills/cpp-mutation/scripts/mutate.ps1`
3. `test-reports/mutants/survivors.md` を読む。
4. 生き残り（SURVIVED）ごとに、どちらかを行う:
   - **殺すテストを書く**: 元のコードで成功し、ミュータントで失敗するテスト。仕様があればそれに、無ければ**元のコードで実行して観測した値**に基づく（特性テスト）。ミュータントとの差分から逆算しない。
   - **等価ミュータントとして除外**: どの入力でも挙動が変わらない場合のみ。`mutants.json` の該当要素に `"equivalent": true, "equivalentReason": "理由"` を追加。「テストが書きにくい」は等価の理由にならない。
5. 追加したテストで殺せたか確認: `mutate.ps1 -OnlySurvivors`（生き残り・未実行・テスト変更前の検出結果だけを再実行する）
6. 最後に cpp-test-gate の `gate.ps1` を実行する。新しくミュータントを検出したテストは、カバレッジが増えなくても合格になる。

ゲートが新規テストの手柄として数えるのは、次のすべてを満たすミュータントだけ:
- そのテストが失敗して検出した（`results.json` の `killedBy` に含まれる）
- ベースラインのテストはどれも検出していない
- 結果が**現在のテストコード**で得られたもの（テストを追加・修正・削除したら `mutate.ps1 -OnlySurvivors` を実行し直す）

スクリプト: [mutate.ps1](./scripts/mutate.ps1)。`results.json`, `killers.json`, `survivors.md` はスクリプト専用（編集禁止）。

## mutants.json の形式

```json
{
  "target": "src/RateLimiter.cpp",
  "mutants": [
    { "id": "M1", "file": "src/RateLimiter.cpp", "line": 42,
      "original": "if (count > limit_)", "mutated": "if (count >= limit_)",
      "fault": "上限ちょうどで拒否してしまう境界バグ" }
  ]
}
```

- `original` はファイルの**1 行の一部をそのまま**コピーする（空白も一致させる）。`line` の ±3 行以内で一意でなければ INVALID になる。一意にならなければ範囲を広げる。
- `mutated` も 1 行。コンパイルが通るものにする（BUILD_ERROR は無効扱い）。

## 良いミュータントの選び方（ACH / Google の知見）

Google の実運用では「開発者にとって意味のないミュータント」を除外することが鍵とされた。量より**現実に起こりそうで、まだテストが捕まえていない**ものを選ぶ。

優先する種類:
- 境界: `<` ↔ `<=`, `>` ↔ `>=`, `== 0` ↔ `<= 0`, ループの `i < n` ↔ `i <= n`
- 条件の反転・欠落: `if (x)` → `if (!x)`, `&&` ↔ `||`, 条件の一方を削除
- エラー処理の欠落: null/範囲チェックの条件を `false` に、エラー戻り値を成功値に、`throw` を通常 return に
- 誤った値: 戻り値を定数（0, 空, `true`/`false`）に、引数の取り違え、`+` ↔ `-`、単位換算の係数
- 副作用の欠落: 状態更新・コンテナ追加・フラグ設定の行の効果を無くす（例: `count_++;` → `(void)0;`、`items_.push_back(x);` → `(void)x;`）

避けるもの:
- ログ出力、アサート、デバッグ用コード、到達不能コード
- 明らかな等価ミュータント（例: 結果に影響しない一時変数の変更、`s >= limit` で `s == limit` のとき同じ値を返すケース）
- 同じ行に 2 個以上

## 等価判定の注意

LLM の等価判定は誤りやすい（Meta の報告でも適合率は約 0.79）。等価とする場合は「どの入力でも観測可能な差が出ない理由」を具体的に書き、迷う場合は等価にせずユーザーに報告する。
