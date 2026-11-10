# Clearcut Mobile

An Android app for listening to radio systems on [Clearcut](https://clearcutradio.app): live calls, transcripts, favorites, and optional push notifications for the calls you care about.

Feature requests and bugs are tracked in [GitHub issues](https://github.com/aidan-lemay/ClearCut_Mobile/issues).

- [Using the app](#using-the-app)
- [Notifications](#notifications)
- [Privacy and security](#privacy-and-security)
- [Building and developing locally](#building-and-developing-locally)
- [Releasing a build](#releasing-a-build)
- [Running a notification relay](relay/README.md)

## Using the app

### Installing

The app isn't on the Play Store. Install it from an APK file:

1. Copy the APK to your phone and open it.
2. If Android asks, allow your browser or file manager to install unknown apps.
3. Play Protect may warn that the app is from an unknown developer. Choose to install anyway.

Updates install over the top and keep your data, as long as they're signed with the same key as the installed copy. If an update won't install, see [Moving to a new phone or reinstalling](#moving-to-a-new-phone-or-reinstalling).

### Listening

- **Systems** lists the radio systems on Clearcut. Pick one to see its talkgroups.
- **Talkgroups** can be searched by name, description or ID. **Show only transcribed talkgroups** hides those without transcripts. Tap a talkgroup to listen to it, or tick several and select **Listen to Selected**.
- **Stream** shows calls as they happen, newest first, and loads older calls as you scroll. Tap play on a call to hear it. **Search Calls** searches the transcripts, looking back through older calls if needed. Calls without a transcript have **Transcribe Call**, which asks Clearcut to transcribe that call.
- **Favorites** saves a talkgroup, or a group of talkgroups, from the Stream page with **Add to Favorites**. Open them from the heart icon at the top of any page. Drag the handles to reorder them, or delete them with the bin icon.

### Hidden systems

Some Clearcut systems aren't in the public list. If you know a system's ID, add it in **Settings > Hidden Systems**. It then appears on the Systems page with a crossed-out eye and works like any other system. If the app can't find talkgroups for that ID, it asks before adding it, since that usually means a typo. Hidden systems can be renamed or removed in Settings.

### Backups

**Settings > Backup** saves to and loads from files you choose, such as in Downloads or a cloud drive:

- **Export Favorites / Import Favorites:** your favorites, in order.
- **Export Settings / Import Settings:** hidden systems, the notification server address, and alert rules. Your access key is never included, so a settings file is safe to keep in a cloud drive.

When importing into an app that already has favorites or settings, you choose whether to replace them or add the new ones after them. Items you already have aren't duplicated.

### Moving to a new phone or reinstalling

Android's automatic backup and phone-to-phone transfer are turned off for this app, because they would copy your access key and a device ID that must be unique to each phone. To move your setup:

1. On the old phone, use **Export Favorites** and **Export Settings**.
2. On the new phone, install the app and use **Import Favorites** and **Import Settings**.
3. If you use notifications, enter your access key in **Settings > Notifications** and select **Connect**. On the old phone, select **Unsubscribe** if you still have it.

Do the same if you ever need to uninstall the app, for example to install a build signed with a different key.

## Notifications

Notifications come from a relay server that someone runs for a group of users, and you need an access key from them. The relay watches Clearcut for you, so your phone keeps no connection of its own, and notifications cost almost no battery. To run a relay, see the [relay's README](relay/README.md).

### Setting up

In **Settings > Notifications**, enter:

- **Server address:** what the relay's operator gave you, such as `relay.example.com`. Addresses use HTTPS unless they start with `http://`. Plain `http://` sends your key unencrypted, so only use it on your own network.
- **Port:** usually left blank.
- **Access key:** starts with `ccr_`. Keep it private, since it lets anyone use the relay as you.

Select **Connect**, allow notifications when Android asks, then select **Send Test Notification**.

### Alert rules

Select **Add Rule**, then choose:

- **What to be notified about:**
  - **Keywords:** transcripts containing one of your keywords. Keywords are separated by commas and match whole words, ignoring case, so `fire` matches "Fire!" but not "firearm". End a keyword with `*` to match word starts, like `fire*`. Phrases like `shots fired` work too.
  - **Transcripts:** every transcribed call.
  - **Every call:** every call as it comes in, updated with its transcript if it gets one.
- **System and talkgroups:** search the list, or use **From favorite** to add a favorite's talkgroups. Transcripts only exist for talkgroups marked with a green tick, so the keyword and transcript options never fire for the others; the editor warns about this.

Switch a rule off to stop it without deleting it.

### Sounds and Do Not Disturb for each rule

Each rule gets its own notification category in Android, named after the rule, under **Alert rules** in **Android Settings > Apps > Clearcut Mobile > Notifications**. Give each category its own sound, vibration, or importance, or let it override Do Not Disturb. For example, make an "every transcript" rule vibrate only, and let a `fire` keyword rule ring through Do Not Disturb.

When one call matches several rules, the notification uses the matched rule whose category is the most urgent: the highest importance, then one that overrides Do Not Disturb. If a call's transcript matches a more urgent rule than the call did, the notification alerts again with that rule's sound instead of updating silently. Deleting a rule removes its category. Test notifications use the **Other alerts** category.

Tapping a notification opens that talkgroup with the call outlined. Nothing plays until you choose to.

### Pausing and unsubscribing

- **Pause Notifications** stops alerts for 1, 4 or 8 hours, or until you select **Resume**.
- **Unsubscribe** removes this phone from the relay. Your rules are kept in case you connect again.

### If notifications don't arrive

- Check that **Send Test Notification** works. If it does, the rules are the place to look: check the talkgroups, and that keyword rules use talkgroups with transcripts.
- If Settings says **The relay isn't up to date**, select **Retry**. The relay may be unreachable from where you are.
- If it says **The relay can't send notifications yet**, the relay has no Firebase key. Tell its operator.
- Check that notifications for Clearcut Mobile, and the rule's own category, are allowed in Android's settings.
- Some phones restrict background apps heavily. If notifications only show up when you open the app, set Clearcut Mobile's battery usage to **Unrestricted** in Android's app settings.
- **"That address doesn't look like a Clearcut relay"** usually means something between you and the relay, such as a login page or bot protection, answered instead. Tell the relay's operator.

## Privacy and security

- **No accounts or analytics.** The app talks to Clearcut directly for systems, calls and audio, and to the relay only if you set up notifications.
- **What the relay keeps:** your phone's push token, your alert rules, whether you're paused, and when you last got a notification. Nothing else about you or your phone. Its operator can see these, and which key your phone uses.
- **What Google sees:** notifications travel through Firebase Cloud Messaging, so Google handles their content: the talkgroup name and transcript text.
- **Your access key** is stored only in the app's private storage, isn't included in backups, and is sent only to the relay you entered.
- **Files you import** are checked before use, and system IDs in them are limited to plain characters, since they end up in web addresses.

## Building and developing locally

These steps build the Android app, the only platform that's released. They were last checked on Linux with Flutter 3.47.9, JDK 17, and Android SDK 36. On Windows or macOS, the Flutter and project commands are the same.

### 1. Install the tools

You need:

- **[Flutter](https://docs.flutter.dev/get-started/install)**, stable channel. The project needs a current version: Flutter refuses to build with older Gradle settings, and older Flutter versions may not accept the newer ones used here.
- **JDK 17.** Newer isn't better here: the Gradle version this project uses can't run on the newest JDKs, even if one is your system default.
- **Android SDK**, from [Android Studio](https://developer.android.com/studio) or the [command line tools](https://developer.android.com/studio#command-line-tools-only). Install `platform-tools`, `platforms;android-36`, and `build-tools;36.0.0`. Gradle downloads anything else it needs, such as the NDK and CMake, during the first build.

On Arch Linux, JDK 17 and `adb` are available with:

```sh
sudo pacman -S jdk17-openjdk android-tools
```

### 2. Point Flutter at them

Adjust the paths for your machine, then accept the SDK licenses and check that the Android toolchain shows no errors:

```sh
flutter config --jdk-dir /usr/lib/jvm/java-17-openjdk
flutter config --android-sdk "$HOME/Android/Sdk"
flutter doctor --android-licenses
flutter doctor
```

`flutter doctor` also reports on desktop and browser tools, which this project doesn't need.

### 3. Get the code

```sh
git clone https://github.com/aidan-lemay/ClearCut_Mobile.git
cd ClearCut_Mobile
flutter pub get
```

The newest work is on the `development` branch, so switch to it with `git switch development` unless you're after what's on `main`.

### 4. Run it on your phone

1. On the phone, turn on **Developer options**, then **USB debugging**, and connect it over USB.
2. Run `flutter devices` to confirm it's listed. If it isn't, accept the prompt on the phone.
3. Start the app:

   ```sh
   flutter run
   ```

While it's running, press `r` to hot reload, `R` to hot restart, and `q` to quit.

The app talks to the live Clearcut API at `clearcutradio.app`, so there's no server to run locally. The **Transcribe Call** button starts real work on that server, so use it sparingly while testing.

### 5. Check your changes

```sh
flutter analyze
flutter test
```

The tests use a fake API, so they don't need a network connection or a device. Audio playback and real push notifications aren't covered, so check those on a phone.

The notification relay has its own tests:

```sh
cd relay
dart test
```

### 6. Build an APK

```sh
flutter build apk --release
```

The APK is written to `build/app/outputs/flutter-apk/app-release.apk`. To install it on a connected phone, run:

```sh
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Android only installs an update signed with the same key as the installed app; otherwise the install fails with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. Builds shared with other people should be signed with the release key:

1. Put the keystore somewhere outside the repository, such as `~/keys/clearcut-release.jks`.
2. Create `android/key.properties`:

   ```properties
   storeFile=/home/you/keys/clearcut-release.jks
   storePassword=...
   keyAlias=clearcut
   keyPassword=...
   ```

Release builds then use that key. Without `key.properties`, they're signed with your machine's debug key, which is fine for testing but differs from machine to machine. Both files are kept out of git. Keep a backup of the keystore and its password: if it's lost, existing installs can't be updated, and everyone has to uninstall and reinstall, losing their settings unless they export them first.

### 7. Turn on push notifications (optional)

Notifications come from the relay in [`relay/`](relay/README.md) and need a Firebase project. Builds work without one, but their notification settings say push isn't available. To include push, put the project's `google-services.json` at `android/app/google-services.json` and rebuild. [The relay's README](relay/README.md#1-set-up-firebase) covers making the Firebase project and running the relay. `google-services.json` is kept out of git.

### Project layout

| Path | What's there |
|---|---|
| `lib/main.dart` | App entry point, shared state, favorites and hidden systems storage, API notes |
| `lib/pages/` | One file per screen |
| `lib/services/backup.dart` | Settings and favorites backup file format |
| `lib/services/notifications.dart` | Alert rules, relay client, and the phone's notification settings |
| `lib/services/alert_notifications.dart`, `firebase_push.dart` | Showing pushes as notifications, and receiving them from Firebase |
| `packages/clearcut_core/` | Live call stream and call data helpers, shared by the app and the relay |
| `relay/` | The notification relay server, with its own [README](relay/README.md) |
| `test/widget_test.dart` | All tests, and the fake API they use |

### How the API behaves

These details shape how the app works:

- **Live stream:** the server drops a stream after about two minutes without data, so reconnecting is normal. Calls sent during a dropped connection are lost, so the app re-fetches after each reconnect.
- **Older calls:** `before_ts` returns calls from before that time, usually about an hour's worth per request. An empty response means there's no older history.
- **Search:** the API has no search, so the app filters on the phone and pages back through history. A search fetches up to 12 pages before asking to continue.

## Releasing a build

For builds you share with other people:

1. **Bump the version** in `pubspec.yaml`, such as `version: 2.8.0+2`. The number after `+` is the build number Android compares, so raise it for every release.
2. **Include push support:** make sure `android/app/google-services.json` is present. Builds without it can't receive notifications.
3. **Sign with the release key:** make sure `android/key.properties` points at it (see [step 6](#6-build-an-apk)).
4. **Build and check the signature:**

   ```sh
   flutter build apk --release
   apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk
   ```

   `apksigner` is in your Android SDK's `build-tools` folder. The certificate should be yours, not `CN=Android Debug`.
5. Share `build/app/outputs/flutter-apk/app-release.apk`.

The first release signed with the release key can't install over builds signed with a debug key. Everyone needs to move over once, as in [Moving to a new phone or reinstalling](#moving-to-a-new-phone-or-reinstalling). Later releases install over the top.
