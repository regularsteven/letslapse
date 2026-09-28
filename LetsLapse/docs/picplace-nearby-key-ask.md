# PicPlace: a key for the account's own devices on the same network — the ask

**Raised:** 2026-09-28 (Steven) · **App side:** not started; built code first once
this is agreed (the app can be built and bench-tested before the server ships it,
with a staged key) · **Read with:** [nearby-originals-plan.md](nearby-originals-plan.md)
(the app's plan), [project-transfer-plan.md](project-transfer-plan.md) (the LAN
transfer it reuses), `docs/letslapse-auth.md` and `docs/letslapse-api.md` in the
picplace repo. **Shareable copy:** https://claude.ai/artifact/6r31s2DwCYbRJfrpWkha3C
(private until shared; republish it whenever this file changes — this file is the
source of truth).

**The ask in one line:** give each LetsLapse account a secret that only its
signed-in, non-revoked devices can read, and replace it whenever a device is
revoked. The devices use it to recognise each other on a local network and open
an encrypted link with no pairing code. PicPlace is never in the data path.

---

## 1. The job, in Steven's words (lightly edited)

> Here's a common problem.
>
> 1. Create a project — let's say a big interval shoot on iPhone (device A).
> 2. The project syncs up with picplace.co — the user has pressed "Sync to
>    PicPlace", so the project's records and preview are up, but the original
>    source photos are still on the device.
> 3. On my Mac (device B), I would like to work with the source files.
>
> Currently I could do the standard PicPlace sync process: (a) upload the
> originals from the iPhone (device A), (b) wait for the originals to upload to
> S3, then (c) download the originals on the Mac (device B), or an iPad Pro
> (device C).
>
> I know this is simple, but it is slow and not 100% efficient, considering the
> two devices are next to one another. Further to that, sometimes it makes more
> sense to manage uploads from one device over another. For example, my Mac
> might have high-speed LAN access, and my iPhone might have cruddy Wi-Fi.
>
> Inside the LetsLapse app, Create ▸ Import a LetsLapse project can already
> import from another device. We have a lot of plumbing in place to manage
> browsing, syncing and connections between two LetsLapse devices.
>
> All of these devices are signed in to PicPlace; they have authenticated. But
> there are mixed levels of what is uploaded at any point. Right now, on this
> network, I have device A "Steve iPhone 18" and device B "Steve iPhone 16". Both
> have the project "Stack 28. 9. at 8:30", but only device A has the original
> source files. Device B can open the project — we see the edit screen and a
> notice: *Preview only — The originals are only on iPhone for now.*
>
> Device B should be able to import the source files from device A. With all the
> authentication green lights, I feel we should not require device A to have
> "Share with nearby devices" turned on (unless there's a good reason), since
> both devices are signed in to PicPlace. There's trust implied. Device B could
> be any PicPlace-authenticated LetsLapse instance.
>
> A user should see:
>
> *Preview only*
> The originals are only on iPhone for now
> **[Import originals from {Steve iPhone 18}]**
>
> If no nearby device is signed in and holds the same project, *Import
> originals* should not be seen. It should only show itself when it's possible.

## 2. What exists today

- **The LAN transfer (since 2026-08-27).** Every LetsLapse device (iPhone, iPad,
  Mac) can serve its library to another over the local network: Bonjour
  (`_letslapse-xfer._tcp`), TLS with a pre-shared key, file by file with a
  windowed acknowledgement. Measured 41 MB/s from an iPhone over USB (11 GB in
  under five minutes). The key comes from a six-digit code the serving device
  shows and the other device types in. Serving is opt-in (Settings ▸ *Share
  projects with nearby devices*, off by default) because a code opens every
  project on the device, including ones that were never synced.
- **PicPlace sync v2.** A project's records bundle and a preview (`poster.jpg`)
  go up; the originals stay on the device that has them until someone uploads
  them. Another device pulls the records and preview and shows the project as a
  *preview*. It can download the originals from PicPlace once they are there.
- **Presence.** Every device posts `tier` with its presence: `original` when it
  holds the sources, `preview` when it holds only the records and poster.

## 3. What the app will do (so the key's job is clear)

1. Every LetsLapse device that is signed in to PicPlace with a connected library
   listens on the local network for **its own account's** other devices, while
   LetsLapse is open. An iPhone can't listen in the background, so a phone must
   have the app open to be found. Steven has accepted that.
2. A device announces itself with an opaque tag that only the account's devices
   can recognise: no device name, no account, no project count on the network.
3. Device B shows a preview whose originals aren't there. It finds device A,
   opens an encrypted connection, and asks whether A holds the originals of
   project X (by origin id). If A holds all of them, B shows **Import originals
   from iPhone 18 Pro**. If no device nearby can supply them, B shows nothing new.
4. When the person presses it, A streams the files over the LAN. B checks each
   file against the SHA-256 in its own synced `assets.ndjson` (so A can't hand
   over a wrong file), puts them in place as a PicPlace download would, and
   posts presence `tier: original`, as it does after a download today.
5. If B has the better uplink, B's normal upload then sends the originals to
   PicPlace. Dedupe by SHA-256 means nothing is stored twice when both devices
   try.

**PicPlace is not in the data path:** no bytes, and no calls per connection.
What the app needs from PicPlace is the **trust**: a secret that the account's
signed-in devices share and nobody else has. The six-digit code does that job
today. For the account's own devices, this key replaces it.

## 4. The ask

### 4.1 A nearby key per account

- 32 random bytes per user, with an id (`key_id`: an opaque string, at most 64
  characters, new with every key).
- Minted when first asked for. Stored encrypted at rest (Laravel's `encrypted`
  cast is fine). Never logged.
- One key per user on this server install. `picplace.test` and `picplace.co` hold
  different keys, as they hold different users.

### 4.2 `GET /api/letslapse/v1/nearby/key`

- Middleware: `CheckToken::using('assets:read')` and `letslapse.device` — a
  registered, non-revoked device, with the same right that downloads originals
  from PicPlace today.
- `200`:

  ```json
  {
    "nearby": {
      "key_id": "nk_7f3a2c",
      "key": "q3v1…(base64url, no padding: 32 bytes = 43 characters)",
      "issued_at": "2026-09-28T10:14:03Z"
    }
  }
  ```

- `Cache-Control: no-store`.
- Errors as elsewhere: `401` for a revoked token (`device_revoked`), `409
  device_required`, `403` for a missing scope.
- Welcome but not needed: record which device fetched which `key_id`, and when.
  It helps support, and answers "which devices hold the current key".

### 4.3 `GET /status` says so, without the secret

```json
"features": { "…": true, "nearby_key": true },
"nearby": { "key_id": "nk_7f3a2c" }
```

- The id only, never the key. `nearby` can be `null` until the first
  `GET /nearby/key` mints a key.
- The app compares `key_id` with the one it holds and fetches the key again when
  they differ, or when it has none. It never polls the key endpoint.
- The app offers nothing nearby-related on a server without
  `features.nearby_key`. The code-based import keeps working as today.

### 4.4 Rotation: a new key replaces the old one

**Must:**

- whenever a device of the account is revoked, by any path:
  `LetsLapseDevice::revoke()` from `DELETE /devices/{id}` on another device, a
  device's own sign-out (the same call on itself), the web, or the console;
- whenever every token of the account is revoked (password reset, "sign out
  everywhere", disabling the account), if those paths exist.

**Nice to have:**

- every 30 days, from a scheduled command. This limits how long a device that
  was never revoked (lost, wiped, abandoned) keeps a working key.

**Not needed:**

- **A grace period or a "previous key".** A device with a stale key fails to
  recognise its peers' tags, re-reads `/status` (rate-limited on the app side)
  and fetches the new key. A transfer already running is unaffected, because
  the key is only used when a connection opens.
- **Rotating when a device is added.** A new device simply fetches the current
  key.

### 4.5 That is all

The server needs no knowledge of which devices are near each other, what they
hold, or what they send. Presence already records what each device holds.

## 5. Why a shared key, and not…

- **Something both devices already know, such as the user's UUID.** It isn't
  secret: it appears in responses and logs, and every device that was ever
  signed in keeps it forever. Revoking a device couldn't take it back.
- **Showing each other their access tokens.** A token is a bearer credential for
  the whole API. A device must never hand one to a peer on the LAN, because a
  fake peer would simply collect it.
- **The six-digit code (today's route).** That is the step Steven wants gone for
  his own devices. It stays for devices that belong to other people, and for
  projects that aren't on PicPlace.
- **Per-device key pairs**: a public key registered with `POST /device`,
  returned by `GET /devices`, with each pair of devices deriving its own key.
  This is stronger: revoking one device needs no rotation, and no single device
  holds a secret shared by all. It is a possible later step, but not now. The
  app's encrypted channel (Network.framework TLS with a pre-shared key) takes
  one key per listener, so pairwise keys would need more cryptography on the
  device than this job warrants. The shared key gives the property that matters
  (only this account's signed-in devices) for a small server change. If you
  would rather do per-device keys from the start, say so: the shape becomes a
  `nearby_public_key` field on `POST /device` and `GET /devices`, and rotation
  goes away.

## 6. How the app uses the key (for your review)

- Kept in the Keychain under the account, beside the tokens. Deleted at sign-out.
- Never used as it is. Everything is derived with HKDF-SHA256, and the key
  itself never crosses the network:
  - **the TLS pre-shared key:** HKDF(key, salt
    `com.regularsteven.letslapse.nearby.v1`, info
    `tls-psk|<server.id>|<user.uuid>`, 32 bytes);
  - **the discovery tag** in the Bonjour TXT record: HMAC-SHA256 under a second
    HKDF subkey (info `discovery`) over the UTC date, cut to 8 bytes. It changes
    every day, so the tag can't be used to follow a device from one day to the
    next. Peers accept yesterday's and tomorrow's tag as well, for clock skew.
    The Bonjour instance name is random too (the default would be the device's
    name).
- **The connection:** TLS 1.3 with the pre-shared key, over the local network
  only (no peer-to-peer Wi-Fi). It is mutual by construction: both ends must
  hold the key. Inside it, each side sends its PicPlace device id, `server.id`
  and `user.uuid`, and either end drops a peer whose ids don't match its own
  account. The app may also check a new peer's device id against
  `GET /devices` (`revoked_at`).
- **When the app uses the key:** only while signed in with a connected library.
  It ignores a cached key when it hasn't confirmed `/status` for 30 days, since
  a device offline that long may have been revoked.
- **What a peer can ask for:** only the originals and blends of projects that
  are on PicPlace in this account, named by the asking device's own records.
  Read-only, and never while the serving device is shooting. Everything else
  (projects never synced, whole libraries) stays behind the six-digit code.

## 7. Threat model, in short

| Who | What they get |
|---|---|
| A stranger on the same Wi-Fi | An opaque service with a tag that changes daily: no name, no account, no project list. They can't complete the handshake. |
| Another device of the same account | What the account can already get from PicPlace (records, previews, and the originals once uploaded), only sooner and over the LAN. |
| A revoked device | Nothing, once its peers hold the new key (at their next `/status`). A connection also needs the serving device to have LetsLapse open. |
| Someone holding a leaked key | While the key lasts: the originals of this account's PicPlace projects, from its devices that are open on the same network. Revoking any device, or the 30-day rotation, ends it. |

## 8. Questions for you

1. Is `assets:read` plus a registered device the right gate for
   `GET /nearby/key`?
2. Which paths besides `LetsLapseDevice::revoke()` revoke a device or all of an
   account's tokens (password reset, account disable, "sign out everywhere"),
   and should rotate?
3. Is the 30-day scheduled rotation easy to add?
4. Mint the key lazily at the first `GET /nearby/key`, or when `/status` is
   first read? Either works for the app.
5. Would you rather do per-device public keys from the start (§5)?

## 9. Not asks: for your information

- **Device names.** iOS gives apps a generic "iPhone" or "iPad". The user's own
  name ("Steve iPhone 18") needs an Apple entitlement. The app will send the
  model instead ("iPhone 18 Pro", "iPad Air 13-inch (M3)") as `name` on
  `POST /device`, so presence rows and the device list read better. Macs keep
  their computer name. No server change is needed: existing rows update at the
  next registration or version report.
- **Presence `tier`.** The app will start reading `tier` from presence rows, to
  name the device that actually holds the originals ("only on iPhone 18 Pro for
  now"). Until now it named the first other device with any presence, which can
  be one holding only a preview. `LetsLapsePresence::toApiArray()` already
  returns `tier`. Please keep it in every presence list the app reads: the index
  rows (`GET /projects`), the project detail, and the presence `POST` response.

## 10. Answers (PicPlace developer, 2026-09-28)

1. **Who can fetch the key:** `assets:read` plus a registered device is right.
   The key unlocks the same originals a download would, and a new scope would
   force every device to sign in again. Unverified accounts and revoked devices
   are already refused.
2. **Other ways a device or account is revoked:** none. `DELETE /devices/{id}`
   is the only thing that revokes anything. A password reset or change leaves
   every token working. There is no "sign out everywhere", and no revoke from the
   web or admin pages. "Disabling" an account sets `users.verified` to false:
   its requests are refused with `403`, but nothing is revoked.
3. **30-day rotation:** easy to add, as one daily scheduled command.
4. **When to create the key:** at the first `GET /nearby/key`. If a device is
   revoked before any key exists, there is nothing to replace.
5. **Per-device keys:** no. One shared key for now, as the ask proposes.

**What the app does with that:** it rotates nothing itself. It drops its key
on `401 device_revoked` and on `403 account_not_enabled`, since a disabled
account revokes nothing and would otherwise keep a working key until the
30-day rotation. It treats a missing `nearby` in `/status` as "no key yet"
and fetches one.

**As built** (picplace `docs/letslapse-nearby-key.md`, 2026-09-28, on
`picplace.test`, not deployed yet): as asked, with two decisions Steven made
the same day. A password reset now signs out every device of the account and
replaces the key. There is no 30-day rotation: it would split devices in the
field (a phone on cellular takes the new key, a Mac on a Wi-Fi without
internet keeps the old one) and wouldn't cut off a lost device that stays
online; the app's own 30-day rule covers abandoned devices. The key is also
switched by `LETSLAPSE_NEARBY_KEY` (off: `features.nearby_key` false and
`404 nearby_key_disabled`), and device summaries gained `revoked_at`.
