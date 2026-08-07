# YuHome cloned-voice TTS

This directory holds the reproducible inputs for cloned-voice prompt generation.
Generated speech must not replace application prompts until it has been reviewed
by the authorized speaker or the project owner.

## Reference

- Source: `entry/src/main/resources/rawfile/voice/prompts/voiceprint_denied.wav`
- Transcript: `声纹验证未通过，指令已拒绝。`
- Prepared input: `reference/voice_reference_16k.wav`
- Format: mono PCM16 WAV at 16 kHz

The prepared file keeps a small amount of leading and trailing context while
removing the long silent prefix and suffix from the packaged prompt.

## Workflow

1. Run zero-shot voice cloning on a GPU using the prepared reference and the
   exact transcript above.
2. Generate every row in `pilot_prompts.json`.
3. Keep model-native output for review and also export 48 kHz mono PCM16 WAV for
   the current DAYU prompt player.
4. Review voice identity, pronunciation, pace, loudness, and artifacts.
5. Only approved output is copied into `entry/src/main/resources/rawfile`.

For arbitrary dynamic text, use the same model behind a TTS service and cache
the returned WAV by normalized text plus voice version. Fixed command feedback
should remain packaged locally as a no-network fallback.
