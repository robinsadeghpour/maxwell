# Privacy: Maxwell for iPhone

Last updated: 19 November 2026 (Live Activity)

This covers the iPhone app "Maxwell for Claude Code". It works with Maxwell on your Mac and shows your Claude Code sessions on your phone. The app is made by Robin Sadeghpour. How it talks to the Mac is described in [phone.md](phone.md).

## In short

- The developer collects nothing. No account, no analytics, no crash reporting, no ads, no tracking.
- Your sessions go only between your phone and your own Mac, end-to-end encrypted.
- The relay that connects them can't read what passes through it, except what your Live Activity shows, if you keep it on.

## What goes where

**Between your phone and your Mac.** Session names, conversations, the terminal, usage, your replies and approvals travel between the phone and Maxwell on your Mac. Each message is encrypted on one device and decrypted on the other, with a key made when you pair. Nobody else holds that key, the developer included.

**The relay.** Your phone and Mac can't always reach each other directly, so both connect to a relay that passes messages along. It runs on Cloudflare. It sees:

- encrypted bytes it can't open,
- your Mac's room id, and SHA-256 hashes of your paired phones' ids, so it knows which phones may join,
- IP addresses, connection times and message sizes, as any server does.

The relay doesn't store messages. It keeps the room's allow-list of hashes and, for the Live Activity, the few things below.

**Live Activity.** With the Live Activity on (Settings › Live Activity, on by default), your lock screen and Dynamic Island show how many sessions need you, are your turn, are working and are at a usage limit, your Mac's name and when the next limit resets, with which account. To update it while the app isn't running, Apple needs a push, and the key for those pushes can't sit in Maxwell on your Mac, because Maxwell is open source. So your Mac sends these numbers to the relay unencrypted, and the relay sends them to Apple. If you also turned on "Show session names" for notifications, the newest session that needs you, its name and what it asks, go the same way. Otherwise no session name or question is sent. The relay keeps the last of these per phone, with the two push tokens iOS gives the Live Activity, until the activity ends or you remove the phone, and keeps no history. Turn the Live Activity off and your Mac stops sending them, and the relay forgets the tokens.

**Notifications.** When a session needs you, your Mac sends a push through Expo's push service and Apple's notification service. The title and text of a notification pass through them readable, like any notification. By default they say only "Maxwell" and "A session needs you". You can choose in the app to show the session's name and question instead. The push token that lets your Mac reach your phone goes to your Mac, encrypted, and never to the developer.

**Signing in to artifacts.** When you open a claude.ai artifact on your phone, your Mac sends that account's claude.ai sign-in cookies, encrypted, so the page opens signed in. The phone keeps them in its Keychain. They're sent only when you open an artifact, and only to claude.ai. Pages you open load from claude.ai, under Anthropic's own privacy policy.

**Dictation.** If you dictate a reply, iOS turns your speech into text. Apple may process the audio, as with any dictation on iPhone.

**Face ID.** If you turn on the app lock, iOS checks your face or passcode. The app only learns whether the check passed.

**Camera.** The camera is used only to scan the pairing code shown on your Mac. Nothing is recorded or sent.

## What stays on your phone

The pairing key and claude.ai cookies are in the Keychain, on this device only. The last state your Mac sent and any replies waiting to be sent are in the app's storage, so the app opens fast and works through a dropped connection.

**Unpair this phone** in the app's settings deletes all of it: the key, the saved state, waiting replies and the cookies, and it ends the Live Activity and tells the relay to forget its tokens. Removing the phone in Maxwell › Settings › Phone on your Mac does the same the next time the phone connects. iOS can keep an app's Keychain items after the app is deleted, so unpair before you delete the app.

## Children

The app is a tool for developers and isn't directed at children.

## Changes

If this changes, this page changes, and its history is in this repository.

## Contact

Questions: open an issue at [github.com/robinsadeghpour/maxwell](https://github.com/robinsadeghpour/maxwell/issues). For something you'd rather not post publicly, use the repository's **Security** tab, then **Report a vulnerability**.
