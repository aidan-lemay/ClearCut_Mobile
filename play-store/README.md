# Google Play listing images

Upload these under **Grow users > Store presence > Main store listing** in Play Console.

| File | Play Console field | Size |
| --- | --- | --- |
| `icon-512.png` | App icon | 512 × 512, 32-bit PNG |
| `feature-graphic.png` | Feature graphic | 1024 × 500, 24-bit PNG |
| `01-stream.png` … `08-correct-transcript.png` | Phone screenshots, in this order | 1080 × 1920, 24-bit PNG |

Screenshots, in order:

1. **Stream:** live calls with transcripts
2. **Call actions:** long press to copy, download or correct
3. **Talkgroups:** choosing several to listen to together
4. **Systems:** every radio system on Clearcut
5. **Alert rule:** notifications for keywords on a talkgroup
6. **Favorites**
7. **Start page:** choosing where the app opens
8. **Correct transcript**

The systems, talkgroups and transcripts shown are made up, so no real radio traffic appears in the listing.

## Making them again

After changing the app, run this from the repository root:

```sh
flutter test tool/store_assets/store_assets_test.dart
```

It runs the real app pages with made-up data and writes every image here. The icon comes from `android/app/src/main/res/mipmap-xxxhdpi/cc_icon.png`. To change the data or the screens, edit [`tool/store_assets/store_assets_test.dart`](../tool/store_assets/store_assets_test.dart).
