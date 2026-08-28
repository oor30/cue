# Cue Phase 2 競合比較・優先順位見直し

調査日: 2026-08-28

## 前提

Phase 1の60分／120分耐久試験と自動品質ゲートは通過済みです。実機fault injectionとDeveloper ID公証はユーザー指示により一時保留のため、Phase 1 MVP PASSは未宣言のままです。

本書はPhase 2候補をそのまま実装せず、「次の顧客会議で手動ChatGPT質問を減らせるか」を基準に優先順位を見直したものです。

## 調査対象

### Cluely

- 会議中の音声と画面を文脈として扱い、`Cmd/Ctrl + Enter`で即時Assistを起動する。
- Transcriptから質問・キーワード・提案をDynamic Actionsとして出し、Tabで先頭候補を実行できる。
- Overlayの表示情報を抑え、詳細TranscriptはDashboard側へ分離している。
- Calendar参加者、過去の会話、People Searchを会議前に短くまとめ、Live Assistの文脈へ渡す。
- 音声取得、キュー、モデル構成等の内部実装は公開されていないため、実装方式は推測しない。

参考:

- https://cluely.com/
- https://docs.cluely.com/feature/liveinsights
- https://cluely.com/blog/people-search-live

### Natively

- Electron/React UI、Rust Native Audio、SQLiteを組み合わせたデスクトップアプリ。
- システム音声とマイクを別系統で扱い、Rolling TranscriptをOverlayへ表示する。
- 過去会議をSQLiteへ保存し、Local RAGと通常Context Windowをフォールバック可能な経路として持つ。
- Screen/Screenshot解析、複数STT、複数LLM、Ollama、グローバルショートカットを提供する。
- 公開実装のmacOSシステム音声取得はScreenCaptureKitを使用し、serial queueと有限queue depthを設定している。
- ライセンスはAGPL-3.0。Cueへコードはコピーせず、二系統分離、有限キュー、Rolling Contextという設計観点のみ参考にする。

参考:

- https://github.com/Dimerin1/natively
- https://github.com/Dimerin1/natively/blob/main/LICENSE

### Fireflies Live Assist

- Meeting Prep、Live Suggestions、Sales Coaching、Live Transcript、Instant Answers、会議後Summaryを一連のUXとして提供する。
- 会議中だけで完結させず、会議前の準備と会議後の記録・検索へ接続する点が強い。
- Source codeやGitをAgentが探索する公開仕様は確認できない。

参考:

- https://fireflies.ai/live-assist

### その他の参考実装

- Project Raven: macOS/Windowsの二系統音声、WebRTC AEC3、複数LLM、Local RAG、Overlayを公開。Cueの将来課題である音響回り込み対策の参考になる。
- NexQ: 二系統文字起こし、複数STT/LLM、Local RAG、Overlay、Follow-up suggestionを提供。

参考:

- https://github.com/Laxcorp-Research/project-raven
- https://github.com/naxhq/NexQ

## 比較表

`△`は一部対応または公開情報だけでは範囲を確認できない項目です。

| 項目 | Cue | Cluely | Natively | Fireflies |
|---|---|---|---|---|
| OS音声取得 | ○ ScreenCaptureKit、system/mic分離 | ○ デスクトップ会議対応、方式非公開 | ○ Native Audio、system/mic分離 | ○ Desktop App/Live Assist、方式非公開 |
| 画面認識 | △ OCRテキスト | ○ 画面文脈 | ○ Screenshot解析 | △ 公開Live Assistの中心機能ではない |
| Realtime回答 | ○ Fast/Deep | ○ Assist/Stealth Chat | ○ 即時回答 | ○ Instant Answers |
| Proactive suggestion | ○ ローカルEvent Detector | ○ Dynamic Actions | △ Follow-up/quick actions | ○ Live Suggestions/Coaching |
| Project context | ○ Project Root/追加参照先 | △ KB、会話Memory | ○ Local RAG、過去会議 | △ 会議・CRM文脈 |
| Source code exploration | ○ Codexがread-only探索 | △ 画面上コードへの回答 | △ Screenshot/文書RAG | 未確認 |
| Git context | ○ Codexが履歴探索可能 | 未確認 | 未確認 | 未確認 |
| Evidence | ○ 構造化済み、UIが弱い | △ 回答文脈はあるがファイル行根拠は未確認 | △ RAG文脈、行単位根拠は未確認 | △ 会議Transcript中心 |
| Fast/Deep | ○ 明示的な2段階 | △ Smart Mode等、内部段階は非公開 | △ Provider/Action分離 | △ Live/会議後処理 |
| Web research | × 現在無効 | △ People Search/会議前調査 | △ Provider依存 | △ 会議前情報連携 |
| Meeting post-processing | ○ Review/Markdown/SQLite | ○ Notes/Memory | ○ Archive/Search/Export | ○ Summary/Search |
| Custom profile | △ モデル定義のみ、UI未完成 | ○ Custom prompt/mode | ○ Provider/quick action | ○ Sales Assist等 |

## Cueの差別化評価

### 強い点

1. Project Root、追加参照先、除外パス、優先ファイルを明示し、Codexが実コードをread-only探索できる。
2. Transcriptだけでなく、ソースコード、仕様書、Git履歴をEvidenceとして同じカードへ載せられる。
3. 質問、要望、決定、TODO、リスクをローカル検出し、AI停止中も会議処理を継続できる。
4. Fast/Deep、topic revision、stale抑止をアプリ側のライフサイクルとして管理している。
5. 画面画像と生音声を保存しない設計を明示している。

### 弱い点

1. Evidenceは構造化されているが、UIではラベルしか見えず、発言やファイルへ移動できない。
2. Event Detectorが単一発話の正規表現中心で、仕様変更、矛盾、停滞をMeeting Stateと比較して検出できない。
3. CluelyのDynamic Actionsのような「候補を一操作で回答へ昇格する」導線が弱い。
4. 過去会議の検索・会議前ブリーフがなく、保存データが次回会議の価値へ接続していない。
5. 画面OCRは現在文字列だけで、画面領域や変化箇所を根拠として提示できない。
6. 外部スピーカー時の音響回り込み抑制がない。

## Phase 2推奨優先順位

### P1. Evidence UI

- カード上で根拠種別、場所、行番号を表示する。
- Transcript根拠から該当発言へ移動する。
- Project File/Source Code根拠からローカルファイルを開く。
- コピー可能な`path:line`表記を提供する。

理由: Cue固有のProject-aware/Evidence-based価値を最短でユーザーが確認でき、AIの誤答時にも会議を止めず検証できるため。

### P2. State-aware Proactive Event Detector

- 要件／決定の変更表現を既存Meeting Stateと照合する。
- 相反する数値、日付、対象範囲をcontradiction候補にする。
- 同一論点の未回答継続をstalledDiscussion候補にする。
- 「次に聞くべき質問」をイベント別に具体化する。

### P3. Fast → Deep昇格

- Fastカードを即時表示した後、重要度・確信度・ユーザー操作に応じてDeepへ昇格する。
- 同じsourceEventIDのカードを置換し、古いカードを増殖させない。
- Deep実行中／更新済み／staleをカード上で理解できるようにする。

### P4. 過去会議検索と会議前ブリーフ

- SQLite FTSで同一Projectの過去決定・TODO・未回答を検索する。
- 会議開始前に最大5件の短いProject Briefを表示する。
- 過去会議Evidenceから該当Reviewへ移動する。

### P5. 高度な画面解析と音響改善

- OCR差分の領域・時刻をEvidence化する。
- 音響回り込みを計測し、必要ならAECを導入する。

## 後回しにする機能

- Claude Code Provider: Codex経路の会議価値を先に磨き、Provider増加による試験行列を増やさない。
- Backlog書き込み: read-only原則と承認UXの設計後に行う。
- Web自動検索: 会議中の誤情報、遅延、外部送信範囲を先に定義する。
- 複数話者識別: 二系統分離のUX改善と音響回り込み対策を先に行う。
- Profiles: System Engineer向けの検出品質を固めてから抽象化する。

## 次のマイルストーン

1. Evidence UI縦切り: 根拠表示、Transcriptジャンプ、ファイルオープン、コピー。
2. State-aware Event Detector: specificationChange/contradiction/stalledDiscussion。
3. Fast→Deep昇格とカード更新状態。
4. 過去会議検索とProject Brief。
5. 保留中の実機fault injection、Developer ID公証を再開し、Phase 1 MVP PASSを最終判定。

## 実装進捗

2026-08-28に次を実装しました。

- Evidence UI: 根拠種別、場所、行番号を表示。
- Transcript根拠: 該当発言へスクロールして強調表示。
- Project File/Source Code根拠: Project Search Policyを再検証してから既定アプリで開く。
- Evidenceコピー: `path:line`または根拠IDをクリップボードへコピー。
- State-aware Event Detector: 既存決定・要望・未解決事項がある場合だけ、明示的な仕様変更、矛盾、停滞を追加検出。
- Fast→Deep: Fastカードから同じsourceEventIDのDeep調査を開始し、カードを増やさず更新。
- 分析順序: Fast実行中はDeep昇格を無効化し、更新競合と二重Deep実行を防止。
- Project Brief: 同一Projectの直近Meeting Stateから未回答、TODO、決定、要望、リスクを最大5件表示。
- 過去会議検索: Transcript FTSの関連度順と、日本語部分一致のエスケープ済みフォールバックを併用。
- 過去Review導線: Briefまたは検索結果から会議を再読込し、根拠発言をスクロール・強調表示。
- Codex Context: Project Briefを過去情報として構造化入力し、現在も有効だと断定しないよう指示。

ユーザー指示により自動テストと実機試験は保留し、`swift build`によるコンパイル確認のみ実施しています。

## Phase 2残機能の実装（2026-08-28）

ユーザー指示「残り全て実装」に基づき、Phase 2で保留していた機能を、安全な最小実装として次まで接続した。

- Fast/Deepスケジューラ: Fast直列、Deep同時1件、同一topicの待機Deepは最新優先。topic変更時は旧分析を取消する。
- 自動Deep昇格: 矛盾、仕様変更、critical、低確信度のhigh、費用・納期・セキュリティ等を対象とする。
- カード永続化: `meeting_id + source_event_id`を一意化し、FastからDeepへの更新でDB重複を残さない。
- 分析状態: queued/running/completed/stale/cancelled/failedをカードに表示する。
- State-aware検出: 明示表現に加え、同一論点の数値・日付・対象値の差分と、未解決論点の時間を空けた反復を検出する。
- 画面Evidence: OCR文字列、信頼度、正規化座標、追加・変更・削除、取得時刻、ScreenCaptureKitの更新領域を保存する。画像は保存しない。
- 音響回り込み抑止: system/micを共通PTSへ揃え、時間重複と日本語bigram類似度でマイク側の重複文字起こしを抑止する。
- 複数話者: 参加者ラベルをProject設定し、会議中・Reviewでsystem側発言へ手動割当して保存できる。Apple標準Speech APIに自動diarizationがないため、自動A/B分離は行わない。
- Claude Code Provider: CLIをsafe mode、Read/Glob/Grep限定、Bash/Edit/Write/Web/MCP禁止、構造化出力、timeout/cancel付きで実装した。接続時に認証状態を確認する。
- Web自動検索: Project単位の明示ONかつCodex選択時だけbrowser searchを許可する。OFF/Claude時は無効。Web根拠は公開HTTP(S) URLと確認時刻を保存し、private/local URLを拒否する。
- Profiles: System Engineer / Sales / Project Manager / Customを選択でき、Base → Profile → Project → Meeting Promptの順で合成する。Profile重点語をローカル検出にも反映する。
- 承認付き資料更新: Project Root内の`.md`/`.txt`だけを対象に、会議決定の追記差分を表示し、明示承認後だけbase SHA256再確認、バックアップ、atomic write、readback検証を行う。
- Backlog: TODOから候補を生成・保存し、確認画面の明示承認後だけ登録する。設定はURL/projectId/issueTypeId/priorityId、APIキーは`WhenUnlockedThisDeviceOnly`のKeychainへ保存する。重複識別子を付け、登録前に既存課題を検索する。
- Meeting Review: 参照したProject/Web/画面根拠、Backlog候補、資料差分案、参加者ラベルをMarkdownへ含める。

実装後は`swift build`、Release app生成、`codesign --verify --deep --strict`まで成功した。ユーザー指示により、自動テスト、長時間試験、実会議、Claude実分析、Web実検索、Backlog実登録、資料の実反映は実施していない。

実装と分けて残る外部条件は次のとおり。

- Claude実分析はClaude Codeのログインと利用可能な契約が必要。
- Backlog実登録は対象SpaceのAPIキーと各IDが必要。
- 自動話者diarizationは話者埋め込みモデル、音声fixture、実機評価を伴う別の品質ゲートが必要。
- Phase 1のfault injection、60/120分の再試験、Developer ID公証は保留中の品質ゲートであり、Phase 2機能実装とは別に実施する。

## 実会議フィードバック対応（2026-08-28）

過去会議動画で確認された「文字起こしを自動復旧中」の反復とFastカードの「更新失敗」を診断し、次を修正した。

- system/microphoneで異なるPTS基準を共有していたため、入力が過去時刻として拒否される問題を、音源別にフレーム数から生成する整数ベースの連続時刻で解消した。
- 復旧成功時は全音源の復旧状態を確認してから`listening`へ戻し、同一音源が60秒内に3回失敗した場合は無限再起動せず明示停止する。
- SpeechTranscriberの暫定結果と確定結果で開始時刻が微修正されても、時間範囲が重なる結果は同じ発言IDへ統合する。
- Fast分析の期限を15秒へ調整し、期限超過は接続障害と分離して「AI更新見送り」と表示する。期限超過ではCodex app-serverを再起動しない。
- Fast待機列は最新2件に制限し、20秒を超えた古い分析はローカル助言を残したまま省略する。

通常自動テスト32件、45秒実音声STT（両系統・マイク単独）、実Codex Read-Only品質ゲート、Release app生成、`codesign --verify --deep --strict`まで確認した。60分／120分の再試験と実会議再試験は保留のままとする。

## 1時間の顧客打ち合わせでの厳格UXレビュー

- 邪魔になる点: Transcript全量とカードが別ペインに流れ、ユーザーが根拠を探すために視線移動を強いられる。
- 邪魔になる点: ローカルカードとCodex更新カードの状態差が分かりにくい。
- 足りない点: 「この回答の根拠を10秒以内に確認する」導線。
- 足りない点: 前回会議の約束、未回答、仕様変更を開始時に思い出させる機能。
- 足りない点: 一般的な確認文ではなく、現在の要件・決定と比較した具体的な次質問。

したがって最初のPhase 2実装は、機能追加数を増やすものではなく、既に生成できるEvidenceを会議中に使える形へ変えるものとします。
