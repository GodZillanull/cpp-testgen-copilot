# C++ 単体テスト自動生成キット（VS Code + GitHub Copilot + Google Test / MSVC）

既存の C++ コード（Visual Studio 2022 / .vcxproj）に、GitHub Copilot のエージェントで Google Test の単体テストを追加するための設定一式です。
基本方針は **「AI が書き、スクリプトが検証して落とし、人間が最終承認する」** です。

## 1. 根拠と、このキットでの対応

| 根拠 | 内容 | このキットでの実装 |
|---|---|---|
| Meta TestGen-LLM (FSE 2024) | 生成テストは候補とし、「ビルド成功 → 安定して成功 → カバレッジ増加」のフィルタを通ったものだけ採用。既存テストは変更しない | `gate.ps1`（5 回シャッフル実行、新規テストごとのカバレッジ寄与、既存テスト削除の検出） |
| Meta ACH (2025) | まだ捕まらない擬似バグ（ミュータント）を作り、それを捕まえるテストを生成 | `cpp-mutation` スキル + `mutate.ps1`（LLM がミュータントを提案し、スクリプトが適用・ビルド・実行・復元） |
| Google のミューテーションテスト運用 | 対象を絞り、開発者にとって意味のあるミュータントだけを出す | ミュータントの選び方と 1 回の上限（`mutation.maxMutantsPerRun`） |
| CoverUp (研究) | 未カバーの行を LLM に明示して反復させる | `coverage.ps1` → `uncovered.md`、プロンプト `/tg-3-coverage` |
| オラクル問題の研究 | LLM は既存コードを読むと現在の挙動（バグ込み）を期待値にしがち | 仕様テスト / 特性テストの区別、`DISABLED_` + `bug_suspects.md`、レビュアーによるオラクル確認 |
| Software Engineering at Google | 振る舞い単位、状態を検証、本物の依存を優先、DAMP | `gtest.instructions.md` |
| Feathers『Working Effectively with Legacy Code』 | 特性テスト、シームによる依存の切り離し | `cpp-legacy-seams` スキル、本番変更は人間の承認制 |

## 2. 構成

```
.github/
  copilot-instructions.md            常時適用されるルール
  instructions/gtest.instructions.md tests/ 配下に適用される Google Test 規約
  agents/
    test-writer.agent.md             テストを書くエージェント（フックで制限付き）
    test-reviewer.agent.md           独立レビュー用（読み取り専用）
  prompts/                           /tg-0-setup 〜 /tg-5-review の手順
  skills/
    cpp-test-gate/                   ベースライン・カバレッジ・ゲート（PowerShell）
    cpp-mutation/                    ミューテーションテスト（PowerShell）
    cpp-legacy-seams/                シームの手法と提案書式
  testgen/
    config.json                      ★ プロジェクトに合わせて編集する
    hooks/guard.ps1                  編集・コマンドを制限するフック
    hooks/stop-check.ps1             ゲート未実行での終了を防ぐフック
.vscode/settings.json                Copilot 側の設定
test-reports/.gitignore              機械生成物をコミットしない設定
```

## 3. 導入手順

### 3.1 前提
- VS Code + GitHub Copilot 拡張（エージェントモード、Agent Skills、カスタムエージェントが使えるバージョン）
- Visual Studio 2022（または Build Tools）の MSBuild。IDE は引き続き VS2022 を使って構いません
- **OpenCppCoverage**（無償）: https://github.com/OpenCppCoverage/OpenCppCoverage/releases からインストール。
  VS2022 Professional / Community には C++ のカバレッジ計測機能が無いため、これで測ります。プロジェクトの変更は不要で、Debug ビルドの .exe と .pdb があれば動きます（行カバレッジのみ）。
- 既存の Google Test のテストプロジェクト（.vcxproj、実行ファイルは gtest の main を持つ .exe）

### 3.2 ファイルの配置
1. `.github/`, `.vscode/`, `test-reports/` をリポジトリのルートにコピーします（既に `.vscode/settings.json` があれば中身をマージ）。
2. `.github/testgen/config.json` を編集します。

| 項目 | 設定内容 |
|---|---|
| `build.project` | ビルドする .sln（または .vcxproj）。VS と同じ出力先にするため **.sln を推奨** |
| `build.extraArgs` | `/t:UnitTests` の部分をテストプロジェクト名に（名前に `.` があれば `_` に置換） |
| `build.configuration` / `platform` | `Debug` / `x64`（カバレッジには Debug + PDB が必要） |
| `tests.executables` | テスト exe のパス（例 `x64/Debug/UnitTests.exe`）。複数可 |
| `coverage.sources` | 計測対象の本番コードのフォルダ（例 `src`） |
| `coverage.excludedSources` | 除外するフォルダ（tests, third_party など） |
| `paths.production` | テストから変更禁止にする本番コードのフォルダ |
| `paths.tests` | テストコードのフォルダ |
| `paths.testProjectFiles` | 新しいテストファイルの登録のためにエージェントが編集してよい .vcxproj / .filters |

3. テストプロジェクトの .pdb が出力されることを確認します（リンカー > デバッグ > デバッグ情報の生成）。

### 3.3 VS Code 側
- フォルダをワークスペースとして開き、ワークスペースを信頼します。
- チャットビューで右クリック → **Diagnostics** を開き、エージェント 2 つ、スキル 3 つ、プロンプト 6 つ、指示ファイルが読み込まれ、エラーが無いことを確認します。
- フック（Preview 機能）は `chat.useCustomAgentHooks` が必要です。組織ポリシーで無効化されている場合、フックによる制限は効かず、指示による制約のみになります（ゲートによる判定は影響を受けません）。

## 4. 使い方

チャットで `/` を入力するとプロンプトが選べます。エージェントは自動で `test-writer` / `test-reviewer` に切り替わります。

| 手順 | コマンド | 内容 |
|---|---|---|
| 0 | `/tg-0-setup` | 環境チェック → ベースライン記録（最初に 1 回） |
| 1 | `/tg-1-analyze src/Foo.cpp` | 振る舞い一覧・仕様の根拠・阻害要因・シーム提案・テスト計画を `test-reports/Foo/analysis.md` に作成（コード変更なし） |
| — | 人間 | analysis.md を確認。シームを承認する場合は空ファイル `.github/testgen/seam-approved` を作成（作業後に削除） |
| 2 | `/tg-2-write src/Foo.cpp` | 計画に沿ってテストを作成し、ゲートを PASS させる |
| 3 | `/tg-3-coverage src/Foo.cpp` | 未カバー行を狙ってテストを追加（最大 3 ラウンド） |
| 4 | `/tg-4-mutants src/Foo.cpp` | ミューテーションで弱いテストを発見し、捕まえるテストを追加 |
| 5 | **新しいチャット**で `/tg-5-review tests/FooTest.cpp` | 書いた側の文脈を持たない独立レビュー（KEEP / FIX / DELETE） |
| — | 人間 | `bug_suspects.md` の判断、差分レビュー、コミット |

1 クラス（またはファイル）ずつ進めるのが安定します。

## 5. 何が機械的に強制されるか

| 項目 | 仕組み |
|---|---|
| ビルド成功・5 回シャッフル実行で全成功 | `gate.ps1` |
| 新規テストが単独でカバレッジを増やす、またはミュータントを殺す | `gate.ps1`（テストごとに `--gtest_filter` でカバレッジ計測） |
| 既存テストの削除・改名の禁止 | `gate.ps1`（`--gtest_list_tests` をベースラインと比較） |
| 本番コードの変更禁止 | `gate.ps1`（ファイルのハッシュ比較）+ `guard.ps1`（編集ツールを拒否） |
| `DISABLED_` テストには bug_suspects.md の記録が必要 | `gate.ps1` |
| ワークフロー・スクリプト・判定結果ファイルの改変禁止 | `guard.ps1` |
| テストを変更したらゲートを実行するまで終了できない | `stop-check.ps1` |
| 期待値の根拠（オラクル）の妥当性 | 機械では判定できないため、指示 + `test-reviewer` + 人間のレビュー |

## 6. 制約と注意点

- **行カバレッジのみ**: OpenCppCoverage は分岐カバレッジを出しません。分岐の取りこぼしはミューテーション（手順 4）で補います。
- **ミューテーションは時間がかかる**: ミュータントごとに増分ビルドとテスト実行を行います。ヘッダのミュータントは再ビルド範囲が広くなるので、.cpp を優先してください。
- **ガードは完全ではありません**: ターミナル経由の書き込みはパターンで検出しているため、抜け道はあり得ます。最終的な防御線はゲートのハッシュ比較と人間の差分レビューです。
- **フックは Preview 機能**です。VS Code の更新で設定名や挙動が変わる可能性があります。動かない場合は Output パネルの「GitHub Copilot Chat Hooks」を確認してください。
- `.vscode/settings.json` の `chat.tools.terminal.autoApprove` は、検証スクリプトの実行承認を省略するためのものです。不要なら削除して構いません。
- スクリプトは Windows PowerShell 5.1 と PowerShell 7 の両方に対応するよう書いています。開発時の動作確認は PowerShell 7 で行いました。

## 7. トラブルシューティング

| 症状 | 対処 |
|---|---|
| `MSBuild.exe not found` | `build.msbuild` に MSBuild.exe のフルパスを設定するか、Developer PowerShell から VS Code を起動 |
| カバレッジが 0% / 対象ファイルが出ない | .pdb の有無、`coverage.sources` のパス、Debug ビルドかを確認。最適化ビルドなら `coverage.optimizedBuild: true` |
| ベースラインで「既存テストが失敗」 | 壊れているテストを `tests.extraArgs: ["--gtest_filter=-Broken.*"]` で一時的に除外 |
| ゲートが遅い | 一度に追加するテストを減らす（新規テストごとにカバレッジ計測するため） |
| ミューテーション中に中断した | 次回 `mutate.ps1` 実行時に自動で元のファイルに戻ります（`test-reports/mutants/.backup`） |
| ベースラインをやり直したい | `test-reports/baseline/` を削除して `/tg-0-setup` |
