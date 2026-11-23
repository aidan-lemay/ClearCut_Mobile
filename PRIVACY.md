# Clearcut Mobile Privacy Policy

**Effective:** November 23, 2026

Clearcut Mobile is an Android app for listening to radio systems on [Clearcut](https://clearcutradio.app). It's made by Aidan LeMay ("we"). This policy explains what the app collects, why, and who it's shared with.

The short version: there are no accounts, ads, analytics or tracking. Most of what you set up stays on your phone. Information leaves your phone only to load calls from Clearcut, and if you choose to submit a transcript correction or turn on notifications.

## What stays on your phone

Your favorites, hidden systems, settings, alert rules and start page are stored only on your phone. If you turn on notifications, so are the relay address and access key you enter. Android's automatic backup is turned off for this app, so none of this is copied to Google's backup service.

Audio you download is saved where you choose. Links you copy go to your phone's clipboard. Neither is sent to us.

If you export a backup, the file goes wherever you save it. A settings backup includes your access key, so keep it somewhere private; favorites and alert rule backups don't include it.

## Listening to calls

The app loads systems, talkgroups, calls, transcripts and audio directly from Clearcut (`clearcutradio.app`). If you select **Transcribe Call**, the app asks Clearcut to transcribe that call. Clearcut is run by a separate operator, not by us. Like any website, it receives your IP address with each request. Its own privacy practices apply.

## Transcript corrections

If you correct a transcript with **Correct Transcript**, the app sends the following to our server at `relay.k5doc.tech`:

- the corrected transcript you wrote, and the original transcript
- which call it's for: the call ID, system, talkgroup and audio file
- when you made the correction
- a random ID the app creates when it's installed (an "install ID")
- your IP address, which our server receives with the request

**Why:** corrections are used to improve the accuracy of Clearcut's transcription. We share them with the operator of Clearcut for that purpose. The install ID and IP address are used to limit how often corrections can be sent and to block spam. They aren't used to identify you, and the install ID isn't linked to anything else about you, including a notification access key.

Corrections are sent only when you submit one. If you're offline, the correction is kept on your phone and sent later. Please don't put personal information in a correction.

**How long:** we keep corrections until they've been used to improve transcription, and the records of senders blocked for spam for as long as the block lasts.

## Notifications (optional)

Notifications are off unless you turn them on. To use them, you need an access key from whoever runs a notification relay, and you enter that relay's address in **Settings > Notifications**. The app then sends that relay:

- a random device ID the app creates
- a push token from Firebase Cloud Messaging, so the relay can send notifications to your phone
- your alert rules, and whether notifications are paused
- your access key, which identifies you to the relay

The relay watches Clearcut for calls that match your rules and sends notifications through **Firebase Cloud Messaging**, a Google service. Google handles your push token under the [Google Privacy Policy](https://policies.google.com/privacy). Notifications include details of the matching call, such as the talkgroup and transcript.

If you use our relay, we keep your registration until you select **Unsubscribe** or your access key is revoked. Our relay's logs include device IDs, access key names and part of push tokens, but never access keys. If you use a relay run by someone else, they receive this information, and their practices apply.

The app asks for permission to show notifications only when you turn notifications on.

## What we don't do

- We don't sell or rent your information.
- We don't use advertising, analytics or crash-reporting services.
- We don't access your contacts, location, microphone, camera, or files other than those you choose to open or save.

## Security

All information sent to our server travels over HTTPS. Our relay stores only hashes of access keys, not the keys themselves.

## Children

Clearcut Mobile isn't directed at children under 13, and we don't knowingly collect information from them.

## Your choices

- **Don't submit corrections**, and nothing about you is sent to our server unless you use our relay for notifications.
- **Unsubscribe** in **Settings > Notifications** to remove your phone's registration from the relay.
- **Uninstall the app** to delete everything it stores on your phone.
- **Ask us to delete corrections** you've sent: email us with roughly when you sent them and which calls they were for.

## Changes

If this policy changes, we'll update it here and change the effective date above.

## Contact

Questions or requests: [clearcutfeedback@aidanlemay.com](mailto:clearcutfeedback@aidanlemay.com)
