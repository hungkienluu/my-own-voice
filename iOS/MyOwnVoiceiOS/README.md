# My Own Voice iOS

This is a first iOS shell for using My Own Voice as a keyboard-based dictation tool.

## Architecture

- The containing iOS app records audio, runs WhisperKit locally on device, and writes the latest transcript to the pasteboard for this development build.
- The keyboard extension stays small: it opens the recorder, polls the latest pasteboard transcript, and inserts the latest text through `UITextDocumentProxy`.
- The keyboard target intentionally does not link WhisperKit or access the microphone. Apple's extension model prevents custom keyboards from using the device microphone directly.

## Local model

The app ships with a model picker for WhisperKit Core ML models:

- `tiny.en`
- `base.en`
- `small.en`

The first run downloads the selected model into the app sandbox. `tiny.en` is the closest lightweight "mini" option for early device testing; `small.en` should be a better quality default once performance is acceptable.

## Setup

1. Open `MyOwnVoiceiOS.xcodeproj` in Xcode.
2. Change the bundle identifiers and App Group ID if needed.
3. Run the `MyOwnVoiceiOS` app on a device. On-device testing is required for real microphone behavior.
4. Enable the keyboard in iOS Settings:
   Settings > General > Keyboard > Keyboards > Add New Keyboard > My Own Voice
5. Turn on Full Access for the keyboard so it can open the recorder app and read the pasteboard transcript.

## Current flow

1. Switch to the My Own Voice keyboard in any text field.
2. Tap `Record`; iOS opens the containing app.
3. Tap `Stop` in the app after speaking.
4. Return to the original app and tap `Insert` on the keyboard.

Automatic return-to-host behavior is intentionally not assumed here because iOS does not provide a robust public API for a custom keyboard to control the host app.
