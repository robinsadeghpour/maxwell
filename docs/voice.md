# Voice mode

Maxwell says which session needs you and what it asks. You answer out loud, and your words are typed into that session, word for word, as if you had typed them. The session carries on by itself. Nothing sits between you and the session: no second agent rewrites the reply.

It is off until you turn it on in Settings › Voice (`voice = on`).

## Using it

- **⌃⌥M** turns voice mode on and off, from any app. An orb appears at the bottom of the screen; its × turns it off too.
- When a session needs you, Maxwell says its name and its question, then listens for 25 seconds. Say your answer. A pause of 1.6 seconds ends it.
- **⌃⌥A**, or a click on the orb, opens the microphone again when the 25 seconds have passed.
- A second session that starts waiting meanwhile is only named ("Billing also needs you"); its question is read once the line is free.
- A reply that is nothing but one of these is a command, in English or German: **skip** (later), **repeat**, **goodbye** (voice mode off). **Cancel** as the last word takes back what you just said. "Skip the tests" is an answer, not a command.
- A permission prompt is said but not answered by voice: it is a menu in the terminal, and a misheard "yes" there costs more than a click.

Both shortcuts can be changed in Settings › Keys.

## What hears and what speaks

**Hearing happens on this Mac**, with the speech model that ships with macOS 26 (`SpeechAnalyzer`). What you say is never sent anywhere. macOS downloads a language's model the first time it is used. One language at a time: `voice-language` (en-US, en-GB, de-DE).

**Speaking** uses ElevenLabs when you give Maxwell an API key (Settings › Voice; kept in the Keychain as "Maxwell voice <app id>"), and this Mac's own voice when you don't. With a key, the lines Maxwell says (session names and their questions) are sent to ElevenLabs: `POST https://api.elevenlabs.io/v1/text-to-speech/<voice>/stream`, model `eleven_flash_v2_5`. `voice-id` picks the voice; empty is "George", the voice of ElevenLabs' own quickstart. A line ElevenLabs refuses is said by the Mac's voice, and Settings › Voice says why.

The microphone is open only for the answer window after a question. An open microphone would type a meeting into a session.

## How the reply reaches the session

A background session is typed into the way the phone app does it (`PhoneTerminals`): a windowless `claude attach` that waits until Claude has drawn, empties the prompt, types the text, waits for its echo and presses Return. It resumes a session Claude Code stopped while idle, and it knows whether the text arrived; if it didn't, Maxwell says so. A session running in one of Maxwell's own terminals gets the text in that terminal. Sessions in another terminal app and cloud sessions are not announced: Maxwell can't type into them.

## The code

| Where | What |
|---|---|
| `Sources/Model/VoiceCall.swift` | The lines said, what a reply means, whose turn it is. Pure, tested in `Tests/VoiceTests.swift` |
| `Sources/Voice/VoiceMode.swift` | The mode: say, listen, send, next |
| `Sources/Voice/VoiceEars.swift` | Microphone to text |
| `Sources/Voice/VoiceSpeaker.swift` | Text to voice, and the key |
| `Sources/Voice/GlobalHotKey.swift` | Shortcuts that work from any app |
| `Sources/UI/VoiceOrb.swift`, `SettingsVoice.swift` | The orb and the Settings tab |
| `Sources/App/MainWindow+Voice.swift` | Which sessions are asked about, and typing into them |

The released app is signed with one entitlement for this, `com.apple.security.device.audio-input` (`packaging/Maxwell.entitlements`): under the hardened runtime macOS refuses the microphone without it and never asks.

## Checking it

A quiet run has no microphone and plays no sound. `Sources/Harness/VoiceHarness.swift` stands in:

- `MAXWELL_VOICE_ONLY=mxtest`: the only sessions the run announces and answers. Without it a scripted run talks to no session, so it can never type into a real one.
- `MAXWELL_VOICE_ON=8`: voice mode on, 8 seconds in. `MAXWELL_VOICE_HEAR="20:Blue please"`: a reply at 20 seconds.
- `MAXWELL_VOICE_FILE=<audio>`: what the speech model hears in a recording. `MAXWELL_VOICE_STREAM=<audio>`: the same recording through the live path, in real time, logging the words as they come and the reply after the pause. `say -o x.aiff "…"` makes a recording without a sound.
- `MAXWELL_VOICE_SNAP=<png>`: the orb as drawn.
- `MAXWELL_ELEVENLABS_KEY`: the key, in place of the Keychain.

The log says `voice: says …`, `voice: heard …`, `voice: sent to …`.

Not covered by a script: the real microphone and its permission question, sound actually playing, and the shortcut from another app.

## Not built yet

An orchestrator: a Claude Code session above the others that you can ask "what's going on" or tell "start a session that…". Today voice mode only carries questions out and answers in.
