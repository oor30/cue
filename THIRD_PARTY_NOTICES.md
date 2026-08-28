# Third-Party Notices

Cue本体はMIT Licenseです。次の依存ソフトウェアとモデルには、それぞれのライセンスが適用されます。

## FluidAudio 0.15.6

- Source: https://github.com/FluidInference/FluidAudio
- License: Apache License 2.0
- Purpose in Cue: macOS上でのオフライン話者分離と話者埋め込み生成

## NemoTextProcessing 0.3.0

FluidAudioのバイナリターゲットとして含まれます。

- Source: https://github.com/FluidInference/text-processing-rs
- License: Apache License 2.0

このバイナリは、Apache-2.0またはMITの許諾を受けたNVIDIA NeMo Text Processing、rustfst、flate2などの成果物を含みます。詳細はFluidAudio配布物の`ThirdPartyLicenses/NemoTextProcessing-LICENSE.md`を参照してください。

Apache License 2.0の全文: https://www.apache.org/licenses/LICENSE-2.0

MIT Licenseの全文: https://opensource.org/license/mit

## 話者分離Core MLモデル

- Distribution: https://huggingface.co/FluidInference/speaker-diarization-coreml
- Upstream projects: pyannote.audio、WeSpeaker

モデルは利用者が設定画面から明示的に準備した場合にダウンロードされます。モデル配布ページに表示されるライセンスと利用条件を、利用時点で確認してください。
