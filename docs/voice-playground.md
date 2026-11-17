# Voice Playground

A separate Vision Pro app for trying terminal voice interactions alongside
SlopZooka. Open **Voice Playground** on the headset; no Mac pairing is needed.

1. Choose **Enable Microphone** and allow speech recognition and microphone access.
2. Look at the microphone at the bottom right, then pinch and hold while speaking.
3. Release. Once the last words settle, a bar fills around the transcript box for
   two seconds.
4. Tap **×** in that window to cancel. Otherwise the message appears
   in the demo with a short mechanical click and a soft border pulse. The transcript
   fades out in place, keeping its position and last words as it disappears.
5. Hold again for another message. Pauses while holding keep the same draft.

Long drafts follow the newest words at the bottom, with older lines fading at
the top. Scroll back to review; new transcription brings the latest line back
into view. The microphone stays free of a visible text label, and recording never
adds a separate Send button during pauses or recognition handoffs.

Messages only appear in this app and clear when its process exits. There is no
companion connection, account, terminal process, or command execution. Allowing
permissions happens before the first hold so permission dialogs do not interrupt
the interaction. If a permission was denied, enable it for Voice Playground in
Settings and try **Enable Microphone** again.

Try a short message, a pause mid-sentence, × near the end of the countdown,
and repeated sends. Check whether two seconds feels right and whether the click
and flash feel satisfying. The feedback is sound and visual motion; this prototype
does not provide physical hand haptics.

The app has its own bundle ID, `com.samragsdale.SlopZookaVoicePlayground`, and
microphone icon. Installing it leaves SlopZooka and its pairing alone. The demo builds the same voice controls and microphone controller as the production
app, with delivery routed to its local message list.

Development and verification commands are in [CONTRIBUTING](../CONTRIBUTING.md#voice-playground).
