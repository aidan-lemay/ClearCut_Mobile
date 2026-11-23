# Clearcut Mobile relay

The relay sends push notifications to Clearcut Mobile. It keeps the always-on connections to Clearcut's live stream and checks every call and transcript against each phone's alert rules. When one matches, it sends a push through Firebase Cloud Messaging. Phones don't need their own connection, so notifications cost them almost no battery.

```
Clearcut stream ──▶ relay (rules, matching) ──▶ Firebase ──▶ phones
```

Phones connect with an access key that you make for each person. The app's alert rules, pause and unsubscribe controls all talk to the relay.

## What you need

- A Linux server with Docker and Docker Compose. These steps were written for Debian.
- A domain name or other address your users' phones can reach, ideally with HTTPS. See [Reaching the relay](#reaching-the-relay).
- The Firebase project that the app is built with. Push only works from the Firebase project whose config is in the app, so one Firebase project serves one build of the app.

## 1. Set up Firebase

Do this once, in a browser:

1. In the [Firebase console](https://console.firebase.google.com), create a project. Google Analytics isn't needed.
2. **Add an Android app** with the package name `com.aidanlemay.clearcut_mobile`. Download `google-services.json` and put it at `android/app/google-services.json` in the app repository. Skip the console's remaining SDK steps; the app is already set up for them. Rebuild the app afterwards. Builds without this file work, but their notification settings say push isn't available.
3. Open **Project settings > Service accounts** and select **Generate new private key**. Save the downloaded file on the server as `relay/data/firebase-service-account.json`.
4. Under **Project settings > Cloud Messaging**, check that **Firebase Cloud Messaging API (V1)** is enabled. It is by default on new projects.

`google-services.json` is kept out of git by `android/.gitignore`. The service account key is a secret: anyone with it can send notifications to every phone using the app. Keep it on the server only.

## 2. Start the relay

On the server:

```sh
git clone https://github.com/aidan-lemay/ClearCut_Mobile.git
cd ClearCut_Mobile/relay
mkdir -p data
cp /path/to/firebase-service-account.json data/
docker compose up -d --build
docker compose logs -f
```

The first build takes a few minutes and runs the relay's tests. The log should say `Sending pushes with Firebase project ...`. If it says pushes are only logged, the relay couldn't find `data/firebase-service-account.json`. It still runs in that state, and the app warns that the relay can't send notifications.

The relay listens on port 8080. To use another host port, change the left side of `"8080:8080"` in `docker-compose.yml`.

## 3. Make access keys

Make one key for each person:

```sh
docker compose exec relay relay keys create alice
```

The key is shown once, starting with `ccr_`. Send it to that person privately. The relay only stores a hash of it, so a lost key can't be recovered: revoke it and make another.

```sh
docker compose exec relay relay keys list            # keys and how many phones use each
docker compose exec relay relay keys revoke alice    # that person's phones stop getting notifications
docker compose exec relay relay devices              # phones, their rules, and when each last got a push
```

Changes to keys take effect in the running relay within 15 seconds. Times in this output are in UTC.

## 4. Connect a phone

In the app, open **Settings > Notifications** and enter:

- **Server address:** the relay's domain or IP address, such as `relay.example.com`. Addresses without `http://` use HTTPS.
- **Port:** only needed if the relay isn't on the standard port, which is 443 for HTTPS and 80 for `http://`.
- **Access key:** the `ccr_...` key.

Then select **Connect**, send a test notification, and add alert rules.

## Reaching the relay

The relay itself only serves plain HTTP. For phones away from home, put it behind something that adds HTTPS, so access keys aren't sent in the clear. Phones then use the relay's domain with no port.

On your home network you can skip HTTPS and enter `http://<server-ip>` with port `8080`. The app warns that the key is sent unencrypted.

### Cloudflare Tunnel

A tunnel gives the relay an HTTPS address without opening ports. You need a domain whose DNS is on Cloudflare.

1. In the Cloudflare dashboard, open **Zero Trust > Networks > Tunnels** and create a **Cloudflared** tunnel. From its install instructions, copy the token after `--token`; you don't need to run the commands.
2. Add a **public hostname** to the tunnel, such as `relay.example.com`, with service type **HTTP** and URL `relay:8080`.
3. In the `relay` folder on the server, create `.env`:

   ```
   TUNNEL_TOKEN=eyJ...
   ```

   and `docker-compose.override.yml`, which Docker Compose merges with `docker-compose.yml` automatically:

   ```yaml
   services:
     cloudflared:
       image: cloudflare/cloudflared:2026.10.3
       container_name: clearcut-relay-tunnel
       restart: unless-stopped
       command: tunnel --no-autoupdate run
       environment:
         TUNNEL_TOKEN: ${TUNNEL_TOKEN}
       depends_on:
         - relay
   ```

4. Run `chmod 600 .env`, then `docker compose up -d`. `docker compose logs cloudflared` should show `Registered tunnel connection`.

The token lets anyone run your tunnel, so keep `.env` on the server. Both files are untracked, so `git pull` leaves them alone.

Two Cloudflare features can block the app:

- **Bot Fight Mode** (Security > Bots) may answer the app with a challenge page meant for browsers. The app then says the address doesn't look like a Clearcut relay. Turn it off for the relay's hostname, for example with a WAF rule that skips bot protection there.
- **Cloudflare Access** login pages can't be used by the app. Don't put Access in front of the relay; its access keys already protect it.

### nginx

To serve the relay behind nginx, which can itself sit behind a Cloudflare Tunnel:

```nginx
server {
    listen 80;
    server_name relay.example.com;

    # The relay refuses request bodies over 512 KB anyway.
    client_max_body_size 1m;

    location / {
        # nginx in Docker, on the same network as the relay. Looking the
        # relay up through Docker's DNS on each request means a rebuilt relay,
        # which gets a new address, is found without reloading nginx.
        resolver 127.0.0.11 valid=10s;
        set $relay http://clearcut-relay:8080;
        proxy_pass $relay;
        # nginx installed on the host instead:
        # proxy_pass http://127.0.0.1:8080;

        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Add a `listen 443 ssl` block with your certificate if nginx terminates HTTPS itself. nginx passes the `Authorization` header through by default; don't strip it, since it carries the access key.

### Caddy

Point a domain at your home's IP address, forward ports 80 and 443 to the server, and use this Caddyfile, which gets a certificate automatically:

```
relay.example.com {
    reverse_proxy localhost:8080
}
```

### Running the relay in an existing Compose file

To run the relay alongside other services instead of with its own `docker-compose.yml`, add this service to your Compose file, adjusting the paths to where the repository is cloned:

```yaml
  clearcut-relay:
    build:
      context: /root/ClearCut_Mobile      # the repository root, not relay/
      dockerfile: relay/Dockerfile
    image: clearcut-relay
    container_name: clearcut-relay
    restart: unless-stopped
    volumes:
      - /root/ClearCut_Mobile/relay/data:/data
    # Reachable only from containers on the same network, such as nginx or
    # cloudflared. If nginx runs on the host, use this instead of "expose":
    #   ports:
    #     - "127.0.0.1:8080:8080"
    expose:
      - "8080"
```

The build context must be the repository root, because the image also includes `packages/clearcut_core`. Stop the relay's own Compose setup first (`docker compose down` in `relay/`), so two relays don't share the data folder. Update with `git pull`, then `docker compose up -d --build clearcut-relay`.

## Transcript corrections

When someone corrects a call's transcript in the app, it's sent to `POST /v1/corrections` here, for retraining transcription later. Unlike everything else on the relay, this needs no access key: anyone with the app can send corrections. They're written to `data/corrections.jsonl`.

### The file

[JSON Lines](https://jsonlines.org): one JSON object per line, oldest first, with every field on every line. Each line is one correction:

```json
{"id":"q3V9x0aB4kL2mN8p","receivedAt":"2026-11-23T18:04:11.402Z","installId":"iX2c...","ip":"203.0.113.5","appVersion":null,"callId":"6740f1...","systemId":"us-ny-monroe","talkgroupId":1001,"audioFile":"audio/us-ny-monroe/1001/1700000000-1.m4a","audioUrl":"https://audio.clearcutradio.app/us-ny-monroe/1001/1700000000-1.m4a","originalTranscript":"engine for to scene","correctedTranscript":"engine four to scene","submittedAt":"2026-11-23T18:04:09.118Z"}
```

| Field | Meaning |
| --- | --- |
| `id` | Made by the relay, unique to this line. |
| `receivedAt` | When the relay got it, UTC. |
| `installId` | A random ID the app makes when it's installed. It identifies one install of the app, not a person or phone, and isn't linked to access keys. |
| `ip` | The address it was sent from, as the relay limits and bans it: IPv4 as is, IPv6 as its /64, such as `2001:db8:1:2::/64`. Behind a proxy, this is only the real sender's address if `RELAY_CLIENT_IP_HEADER` is set. |
| `appVersion` | Reserved for the app's version; currently always `null`. |
| `callId`, `systemId`, `talkgroupId` | The call, as Clearcut identifies it. |
| `audioFile`, `audioUrl` | The call's audio, as Clearcut's path and as a full URL. May be `null`. |
| `originalTranscript` | Clearcut's transcript when the correction was made. Empty if there wasn't one. |
| `correctedTranscript` | The person's correction. |
| `submittedAt` | When the person made the correction, by the phone's clock. Sent later if the phone was offline. |

If the same install corrects a call twice, both lines are kept; use the later one. To read it in Python:

```python
import json
with open("corrections.jsonl") as f:
    corrections = [json.loads(line) for line in f]
```

To hand over a batch, copy the file and then empty it, so the next batch starts fresh:

```sh
cp data/corrections.jsonl corrections-$(date +%F).jsonl && : > data/corrections.jsonl
```

### Limits and filtering

Because this endpoint is public, it assumes a sender may be a bot:

- **Rate limits:** each IP address can send 30 corrections an hour, each install 200 a day, and everyone together 5,000 a day. IPv6 addresses are limited by their /64 network, so one phone can't dodge the limit by changing address. Requests over a limit get `429`, or `503` for the daily total, with `Retry-After`. Malformed requests count against the IP limit too, so a flood of junk is limited the same way. The app keeps corrections that were turned away and sends them later.
- **Filtering:** requests must be JSON and under 16 KB. Every field is checked: IDs must look like Clearcut IDs, transcripts must be under 4,000 characters, a correction must differ from the original, and control characters and web links are refused.
- **Disk:** once `corrections.jsonl` reaches 200 MB, new corrections are refused until it's emptied.
- **Browsers:** the relay sends no CORS headers and requires a JSON content type, so a web page can't make its visitors' browsers send corrections.
- **Logs:** refusals are logged once per sender per hour, so a flood can't fill the relay's logs either.

### Strikes and bans

Senders can be banned by install ID or IP address, by you or automatically. **Banned senders aren't told:** their corrections get the usual success reply but aren't logged, so a bot keeps using an ID you're already ignoring instead of making a new one.

**Automatic bans.** Each refused request is a strike against the sender's IP address, and against its install ID if the request had one. A request is refused for invalid data, a link, being too large or not JSON, or going over a rate limit. 10 strikes in a day (`RELAY_CORRECTIONS_STRIKES`) bans the sender:

| Automatic ban | Install ID | IP address |
| --- | --- | --- |
| First | 1 day | 1 day |
| Second | 7 days | 7 days |
| Third and later | For good | 7 days |

IP addresses are never banned for good automatically, because a phone carrier can put many people behind one address. The app itself never sends invalid corrections, so real users are very unlikely to collect strikes. Each automatic ban is logged, like `Banned install iH7dK2pQ… for 1 day after 10 refused requests (last: Corrections can't contain links.)`.

**Banning by hand:**

```sh
docker compose exec relay relay corrections senders             # installs by how many corrections they've sent
docker compose exec relay relay corrections ban <install ID> --reason "spam" --purge
docker compose exec relay relay corrections ban 203.0.113.5 --days 7
docker compose exec relay relay corrections bans                # every ban, automatic and manual
docker compose exec relay relay corrections unban <install ID or IP>
```

- `--purge` also deletes the corrections that install or IP address already sent.
- `--days` ends the ban after that many days; without it, the ban lasts for good.
- IPv6 addresses are banned by their /64, as they're limited.
- Bans apply to the running relay at once and are kept in `data/bans.json`.
- `unban` also forgets the sender's history, so a later automatic ban starts at 1 day again.

`senders` shows the IP address each install last sent from. Requests that were refused aren't in `corrections.jsonl`, so for those, look in `docker compose logs relay` for lines like `Corrections rate limited for IP 203.0.113.5`.

### Settings

Change the limits with these environment variables, in `docker-compose.yml` under `environment:`:

| Variable | Default |
| --- | --- |
| `RELAY_CORRECTIONS_PER_IP_PER_HOUR` | `30` |
| `RELAY_CORRECTIONS_PER_INSTALL_PER_DAY` | `200` |
| `RELAY_CORRECTIONS_PER_DAY` | `5000` |
| `RELAY_CORRECTIONS_MAX_MB` | `200` |
| `RELAY_CORRECTIONS_STRIKES` | `10` refused requests a day before an automatic ban |
| `RELAY_CORRECTIONS` | Set to `off` to turn corrections off. |

Rate limits and strike counts are kept in memory, so restarting the relay resets them. Bans are kept on disk and aren't reset.

### Behind a proxy or tunnel: set `RELAY_CLIENT_IP_HEADER`

Behind Cloudflare, nginx or Caddy, every request reaches the relay from the proxy's address, so without this setting **everyone shares one IP limit**. Tell the relay which header holds the sender's real address:

| In front of the relay | Set `RELAY_CLIENT_IP_HEADER` to |
| --- | --- |
| Cloudflare Tunnel | `CF-Connecting-IP` |
| nginx, with the config above | `X-Real-IP` |
| Caddy | `X-Forwarded-For` |

```yaml
services:
  relay:
    environment:
      RELAY_CLIENT_IP_HEADER: CF-Connecting-IP
```

Only set this when the relay can't be reached except through that proxy. Anyone can send these headers, so if the relay's port is also open directly, a bot could make up an address for every request. With the Compose setups above, keep the port on `127.0.0.1` or use `expose` instead of `ports`. When the header isn't set, the relay says so in its log at startup.

### Extra protection with Cloudflare

If the relay is behind Cloudflare, a rate limiting rule there stops floods before they reach your server. Under **Security > WAF > Rate limiting rules**, add a rule matching **URI Path equals `/v1/corrections`**, counting by IP, for example 20 requests per minute, with action **Block**. The free plan includes one such rule.

## Updating and backups

```sh
git pull
docker compose up -d --build
```

Everything the relay keeps is in `relay/data`: `keys.json`, `devices.json`, `corrections.jsonl`, `bans.json` and the Firebase key. Back up that folder to keep keys and registered phones. If `devices.json` is lost, phones re-register the next time their notification settings change or the app restarts.

## Security

- **Access keys** are 256-bit random values. The relay stores only their SHA-256 hashes, so `keys.json` doesn't give anyone access. Each phone stays tied to the key it registered with, so one person can't change or remove another person's phone.
- **Limits:** a key can register up to 10 phones (`RELAY_MAX_DEVICES_PER_KEY`), each with up to 50 rules covering up to 10 systems. Requests over 512 KB are refused. These stop a leaked key from making the relay open unlimited Clearcut connections. If a key leaks, revoke it.
- **Transcript corrections** are the one thing that needs no key. See [Limits and filtering](#limits-and-filtering) and [Strikes and bans](#strikes-and-bans) for how they're protected, and set `RELAY_CLIENT_IP_HEADER` behind a proxy.
- **The Firebase service account key** can send notifications to every phone with the app. Keep it only in `relay/data`, and restrict the folder: `chmod 700 relay/data`.
- **HTTPS:** the relay serves plain HTTP, so put HTTPS in front of it (see [Reaching the relay](#reaching-the-relay)) for anything beyond your home network.
- **Logs** include phone IDs, key names, and the start of push tokens, but never access keys.
- **The container** has no shell or other programs, only the relay itself.

## Troubleshooting

All of these start with `docker compose logs relay`.

| What you see | What it means |
|---|---|
| `pushes are only logged, not sent` | `data/firebase-service-account.json` is missing. Add it and run `docker compose restart`. |
| `Push failed with 403` or `401` | The Firebase key is from a different project than the app's `google-services.json`, or the Cloud Messaging API is turned off. |
| `Removing device ...: its push token is no longer valid` | That phone uninstalled the app or reset its push registration. It re-registers when the app next opens. |
| `SSE error: ... Connection closed` every couple of minutes | Normal. Clearcut drops quiet streams, and the relay reconnects. |
| The app says the key wasn't accepted | The key was revoked or mistyped. `relay keys list` shows the keys that exist. |
| The app says the address doesn't look like a relay | Something else answered: check the proxy or tunnel settings and Cloudflare's bot protection. `curl https://relay.example.com/healthz` should print `{"ok":true}`. |
| `This access key already has 10 phones registered` | That person has too many phones registered. Phones are removed when they unsubscribe or uninstall the app; raise `RELAY_MAX_DEVICES_PER_KEY` if needed. |

## How rules are matched

- **Every call:** a notification for each call, updated with its transcript if one arrives. The update replaces the first notification without making a second sound.
- **Every transcript:** a notification once each call is transcribed.
- **Transcripts with keywords:** only transcripts containing a keyword. Keywords match whole words and ignore case, so `fire` matches "Fire!" but not "firearm". End a keyword with `*` to match the start of words, like `fire*`. Phrases like `shots fired` work too.

Each push includes the IDs of the rules it matched, so the app can show it in the notification category of the rule the user set as most urgent.

Transcripts only exist for talkgroups that Clearcut transcribes, so the transcript modes never fire for other talkgroups. The app warns about this when making a rule.

The relay opens one Clearcut connection per system, covering the talkgroups that active rules need. It reconnects whenever Clearcut drops the stream, which Clearcut does after about two minutes without calls. Phones that are paused, or rules that are switched off, aren't watched.

## Running without Docker

With the [Dart SDK](https://dart.dev/get-dart) installed:

```sh
cd relay
dart pub get
dart test
RELAY_DATA_DIR=data dart run bin/relay.dart serve
```

Settings, from environment variables:

| Variable | Default | |
|---|---|---|
| `RELAY_PORT` | `8080` | Port to listen on |
| `RELAY_DATA_DIR` | `data` (`/data` in Docker) | Where keys, phones and the Firebase key are kept |
| `FCM_CREDENTIALS` | `$RELAY_DATA_DIR/firebase-service-account.json` | The Firebase service account key |
| `RELAY_MAX_DEVICES_PER_KEY` | `10` | How many phones one access key can register |

## API

Phones use this; it's listed for troubleshooting. Every request except `/healthz` needs an `Authorization: Bearer <key>` header.

| Request | |
|---|---|
| `GET /healthz` | `{"ok": true}` if the relay is running |
| `GET /v1/status` | Checks a key. Returns the key's name and whether pushes go through Firebase (`"push": "fcm"`) or are only logged (`"log"`) |
| `PUT /v1/devices/<id>` | Registers or updates a phone: its push token, rules, and pause |
| `DELETE /v1/devices/<id>` | Unsubscribes a phone |
| `POST /v1/devices/<id>/test` | Sends the phone a test notification |

A phone is tied to the key it registered with, so one person's key can't change another person's phone.
