# Clearcut Mobile

See https://github.com/aidan-lemay/ClearCut_Mobile/issues for current feature tracking

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

The tests use a fake API, so they don't need a network connection or a device. Audio playback isn't covered, so check that on a phone.

### 6. Build an APK

```sh
flutter build apk --release
```

The APK is written to `build/app/outputs/flutter-apk/app-release.apk`. To install it on a connected phone, run:

```sh
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Release builds are currently signed with the debug key, which is unique to each machine. If the phone already has a build from another machine, the install fails with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. To keep your favorites, build with the original machine's `~/.android/debug.keystore`. Uninstalling the old build also works, but it deletes your favorites.

### Project layout

| Path | What's there |
|---|---|
| `lib/main.dart` | App entry point, shared state, favorites and hidden systems storage, API notes |
| `lib/pages/` | One file per screen |
| `lib/services/sse_service.dart` | Live call stream, including reconnecting |
| `lib/services/call_utils.dart` | Merging and formatting call data |
| `lib/services/backup.dart` | Settings and favorites backup file format |
| `test/widget_test.dart` | All tests, and the fake API they use |

### How the API behaves

These details shape how the app works:

- **Live stream:** the server drops a stream after about two minutes without data, so reconnecting is normal. Calls sent during a dropped connection are lost, so the app re-fetches after each reconnect.
- **Older calls:** `before_ts` returns calls from before that time, usually about an hour's worth per request. An empty response means there's no older history.
- **Search:** the API has no search, so the app filters on the phone and pages back through history. A search fetches up to 12 pages before asking to continue.

