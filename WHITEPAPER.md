# RedCourier — Technical Whitepaper

## Concept

RedCourier sends end-to-end encrypted files between the members of a group.
The group needs no server of its own. Two kinds of third-party services are
used, and neither ever sees plaintext:

- **A shared WebDAV folder** (for example on Nextcloud) holds exactly one file,
  `sync.json`: the signed and partly encrypted state of the group, with the
  members and the encrypted links of every delivery.
- **Public file sharing services** (filebin.net, temp.sh, litterbox, termbin) hold the
  deliveries themselves: encrypted, packed into ZIP parts with random names.

Every client downloads `sync.json`, verifies it, decrypts what it is allowed to
read and shows the deliveries addressed to the user. Sending means packing and
encrypting the files locally, uploading the parts to the file hosts and adding
a signed entry with the encrypted links to `sync.json`. A recipient downloads
the parts, checks them, joins them and decrypts the delivery.

The approach is the same as in CalSec: an encrypted file synced through a
third-party service, with signatures and a fingerprint as trust anchor.

All network traffic goes through Tor, and every sealed key uses a hybrid of
classical and post-quantum cryptography.

## Algorithms

| Purpose | Algorithm |
| ------- | --------- |
| Encrypt to a user ("seal") | hybrid X25519 + ML-KEM-768 (FIPS 203), HKDF-SHA256, AES-256-GCM |
| Symmetric encryption | AES-256-GCM, random 96-bit nonce |
| Signatures | Ed25519 |
| Hashes, ids, fingerprints | SHA-256 |
| Local vault | PBKDF2-HMAC-SHA256 (300 000 iterations) + AES-256-GCM |

All operations are pure Dart, so they behave the same on every platform:
the `cryptography` package for the classical algorithms and `pqcrypto` for
ML-KEM. The ML-KEM implementation is pinned and checked in the test suite
against values computed with the independent `kyber-py` reference.

### Hybrid sealing

```text
x_ss         = X25519(ephemeral, recipient enc_pub)
(kct, k_ss)  = ML-KEM-768.Encaps(recipient kem_pub)
key          = HKDF-SHA256(ikm  = k_ss || x_ss,
                           salt = eph_pub || enc_pub || SHA-256(kct) || SHA-256(kem_pub),
                           info = "redcourier/seal/v2/" || context)
sealed       = { epk, kct, h, n, ct = AES-256-GCM(key, data, aad = context) }
```

An attacker has to break both X25519 and ML-KEM-768 to recover a key. Data
recorded today therefore stays protected even against a future quantum
computer ("harvest now, decrypt later"). The 8-byte tag `h` is derived from
the X25519 secret only; it lets a recipient skip the slower ML-KEM step for
values that are not addressed to them.

Signatures stay Ed25519. A signature only has to resist forgery at the time
it is checked, so a quantum computer in the future cannot change what clients
have already verified. ML-DSA can be added the same way when needed.

## Keys

| Key | Held by | Purpose |
| --- | ------- | ------- |
| User encryption keys (X25519 + ML-KEM-768) | each user | receive group keys and entry keys |
| User signing key (Ed25519) | each user | sign own entries |
| `group_key` (AES-256) | all members | encrypt member names |
| `files_sign_key` (Ed25519) | all members | sign the file list |
| `admin_sign_key` (Ed25519) | admins | sign the user list |
| entry key (AES-256) | sender + recipients | encrypt one entry |
| payload key (AES-256) | sender + recipients | encrypt one delivery |

A user id is `SHA-256(enc_pub || sig_pub || kem_pub)`, truncated to 128 bits. It is derived
from random public keys, not from the identifier.

## sync.json

```text
{
  format: "redcourier-sync", format_version: 3,
  users: {
    version,                          signed counter
    sign_keys: { admin, files },      Ed25519 public keys
    members: {
      <user_id>: {
        enc_pub, sig_pub, kem_pub,    X25519, Ed25519, ML-KEM-768
        role,                         admin | member | removed
        group_key:      seal[enc_pub](group_key),
        files_sign_key: seal[enc_pub](files_sign_key),
        admin_sign_key: seal[enc_pub](admin_sign_key)    admins only
      }
    },
    user_details: enc[group_key]({ <user_id>: identifier }),
  },
  users_sig: sig[admin_sign_key](format, format_version, users),

  files: {
    version,
    entries: {
      <entry_id>: {
        sender, created, expires,     plain, so expired entries can be cleaned up
        recipients: [ seal[enc_pub_i](entry_key), … ],   unlabeled, shuffled
        data: enc[entry_key]({
          note, to,
          files:   [{ name, size }],
          payload: { id, key, parts: [{ host, url, size, sha256, expires }] }
        }),
        sig:  sig[sender's signing key](entry_id, entry)
      }
    }
  },
  files_sig: sig[files_sign_key](format, format_version, files)
}
```

Every signature uses a domain prefix (`redcourier/users/v1`, …) over canonical
JSON (sorted keys, no whitespace). Every sealed value and every ciphertext is
bound to its purpose through the HKDF info or the AES-GCM associated data, for
example `entry-key/<entry_id>`, so values cannot be moved to another place.

### Deliveries at file sharing services

```text
files ──zip──▶ payload.zip ──encrypt──▶ payload.rcb ──split──▶ part_1 … part_n
part_i ──wrap in a ZIP (one entry "redcourier.part")──▶ <random>.zip ──▶ upload
```

The payload is encrypted in 1 MiB chunks with a fresh random key:

```text
"RCB1" | chunk size | 8-byte nonce prefix | chunk_0 | chunk_1 | …
chunk_i = AES-256-GCM(payload_key, nonce = prefix || i,
                      aad = payload id || i || final flag)
```

The final flag detects truncation, the payload id in the associated data stops
one payload from being swapped for another. Decryption writes to a temporary
file and only keeps it when every chunk verified.

Large payloads are split into parts of at most 256 MiB. Each part is cut to
the limit of the host that receives it, and part *i* goes to the *i*-th host in
turn, so a delivery is spread over several services; if a host fails, the next
one is tried. A host whose limit would need more than 32 parts for the delivery
is skipped, so small hosts only carry small deliveries. A host is only used if it keeps files at least as long as the delivery
should live, which limits deliveries to about six days.

For every part the entry stores the host, the link, the size and the SHA-256
of the uploaded ZIP. On download each part is checked against both before it
is used. Links are only accepted for the domains of the known hosts, so a
manipulated entry cannot make clients fetch arbitrary addresses. The sender
deletes the parts where the host allows it (filebin) when the delivery is
deleted or expires.

| Host | Upload | Limit | Kept |
| ---- | ------ | ----- | ---- |
| filebin.net | HTTPS POST, raw body with `Content-SHA256` | 500 MB | about 6 days, deletable |
| temp.sh | HTTPS multipart | 4 GB | 3 days |
| litterbox | HTTPS multipart, `time` = 1h/12h/24h/72h | 1 GB | up to 3 days |
| termbin.com | raw TCP port 9999 through Tor, part as Base64 text | about 24 KB per part | one week (used for up to 6 days) |

termbin accepts plain text only, so a part is sent as Base64 and decoded after
download; its 32 KB buffer makes it useful only for small deliveries (notes,
short documents). The upload goes through a SOCKS connection of Tor, the
download over HTTPS.

gofile.io is not supported: downloading through its API needs a premium
account or a token taken from the obfuscated website code, which changes
without notice. 0x0.st blocks Tor and forbids automated uploads, oshi.at had an
invalid certificate.

Uploads and downloads can be stopped. A stopped upload publishes nothing and
deletes the parts already uploaded where the host allows it. A download keeps
every finished part on the device (encrypted, in the group's folder, with a
small progress file) and continues with the first missing part on the next
attempt, also after a restart of the app. The partial data is deleted when the
download completes or the delivery is removed, hidden or expired.

The hosts see only ZIP files with random names and encrypted content, their
size and the upload and download times (through Tor). They do not see file
names, notes, senders or recipients.

## Changes compared to the first draft

| Draft | Problem | Now |
| ----- | ------- | --- |
| `users` keyed by `hash(identifier)` | identifiers like e-mail addresses can be brute-forced from an unsalted hash | ids are hashes of the public keys |
| `kpub: kpub_hash(identifier)` beside an encrypted key list | public key and entry could disagree (see user Z in the draft) | `enc_pub` and `sig_pub` sit in the signed entry, the id is checked against them |
| `users_sig` without a public key | clients had nothing to verify against | `sign_keys.admin` is in the file and pinned by a fingerprint |
| only the admin gets the file signing key | ordinary users could not send | every member gets `files_sign_key`, every entry is additionally signed by its sender |
| files keyed `1, 2, …` | two senders pick the same number | random 128-bit entry ids |
| no versions | an old file could be replayed | signed `version` counters, clients reject lower versions |
| plain overwrite on upload | concurrent writers lose each other's changes | `If-Match` with the ETag; on conflict the change is re-applied to the newer file |
| `to: { hash(id): … }` | the server sees who receives what | recipient keys are unlabeled and shuffled; recipients try to open them |
| no file integrity, no expiry handling | – | per-chunk AEAD, SHA-256 per uploaded part, `expires` is signed and expired entries are removed |
| no key rotation | removed users keep all keys | removing a user replaces `group_key` and `files_sign_key`, and `admin_sign_key` if it was an admin |

## Network: everything through Tor

RedCourier never opens a direct connection. Like CalSec it uses Tor in one of
two ways.

**SOCKS proxy (default).** Every connection is opened through Tor's SOCKS5
port, the equivalent of `socks5h://127.0.0.1:9050`. Dart's HTTP client gets a
connection factory that performs the SOCKS handshake; for HTTPS, TLS is then
negotiated end to end on top of the Tor connection. No local port is opened.

- Host names go to Tor unresolved (SOCKS5 with domain names), so there are no
  DNS leaks and `.onion` WebDAV servers work.
- Each group on the device sends different SOCKS credentials, so Tor builds
  separate circuits per group (and separate ones for file hosts and
  updates). A server cannot link two groups of the same person through a
  shared exit node.
- Proxy settings from the environment (`http_proxy` and similar) are ignored.
- If Tor is not reachable, requests fail with an error instead of falling back
  to a direct connection.

Tor is looked for on 127.0.0.1:9050 (Tails, the tor service, Orbot) and :9150
(Tor Browser). A fixed port can be set in the settings, which also offer a
check against check.torproject.org.

**torsocks.** If the app is started with `torsocks` (detected through
`LD_PRELOAD`), torsocks already redirects every connection into Tor and
resolves names through Tor. torsocks refuses connections to 127.0.0.1,
including Tor's SOCKS port, so in this mode the app connects normally and lets
torsocks route the traffic. Because the app cannot see where its connections
go, it first asks check.torproject.org whether the traffic arrives through Tor
and refuses to continue otherwise. torsocks cannot separate circuits per group;
the Tails menu entry therefore starts the app without torsocks.

**Guarantees, in layers.**

1. *One place.* All connections are opened in `lib/core/tor.dart`. A test
   (`test/network_guard_test.dart`) fails if any other file creates an HTTP
   client, opens or listens on a socket, sends UDP, resolves DNS, uses a
   WebSocket or a network package, or starts another program (only the
   updater may run the local installer).
2. *Runtime guard.* The first thing `main()` does is install process-wide
   overrides: every `HttpClient` created by any Dart code, also inside
   packages, connects through Tor, and every `Socket.connect` to anything but
   Tor's SOCKS port on 127.0.0.1 fails. A forgotten direct call is blocked
   rather than silently sent. Under torsocks sockets are left to torsocks.
3. *Limits of the app.* The guard covers Dart code. Native code in plugins
   could in principle open its own connections; none of the plugins used
   (camera, QR decoder, notifications, file picker) does.
4. *Operating system.* The independent guarantee comes from the system:
   the Tails firewall, Orbot as always-on VPN with "block connections without
   VPN" on Android, or a firewall rule on Windows (see the README).

While a group is unlocked, the app downloads `sync.json` every 10 minutes and
when it returns to the foreground. New deliveries can raise a local
notification ("2 new deliveries", no sender or group name, private on the
Android lock screen). There is no push service and no background job: a locked
or closed app does not sync, because the keys are only in memory while the
group is unlocked. The WebDAV server sees the regular downloads as a pattern.

## Several groups on one device

The group is the only unit of separation. A device can hold several groups,
for example "Work" and "Family", and nothing is shared between them:

- every group has its own identity (keys and identifier) and its own password,
- every group uses its own WebDAV folder and therefore its own `sync.json`;
  the app refuses to connect two local groups to the same folder,
- every group has its own Tor circuits, cache and download folder.

Members of one group never learn about the user's other groups. The local
group name is only shown on the device. The unlock screen chooses the group
and can mark one to open at start.

## Trust

The **group fingerprint** is `SHA-256(canonical_json({admin_sign_key}))`, shown as
64 hex characters in groups of four. The admin key signs the user list, which
contains the file signing key and all members, so the fingerprint anchors
everything else.

1. A new user creates an identity and sends the **join request**
   (`RCJOIN2:…`, identifier and public keys) to an admin.
2. The admin compares the user id with the user and adds them.
3. The admin sends an **invite** (`RCINVITE2:…`, WebDAV URL and credentials)
   and, over a **second channel**, the **fingerprint**. The invite deliberately
   does not contain the fingerprint: an attacker who controls one channel could
   otherwise send an invite to their own server together with the matching
   fingerprint. The fingerprint is sent as text (for example by e-mail; spaces,
   line breaks and case are ignored) or shown as a QR code (`RCFP1:<hex>`) that
   the Android app scans with the camera. Decoding runs on the device (zxing);
   no image leaves it.
4. On the first sync the client only accepts `sync.json` if the admin key
   matches the fingerprint the user entered and all signatures verify.
5. Later syncs check against the stored key. If it changes (an admin was
   removed or demoted), the user must enter or scan the new fingerprint from an
   admin.

Rotating the file signing key does not change the fingerprint, so removing an
ordinary member needs no re-confirmation.

## Roles

| Action | member | admin |
| ------ | :----: | :---: |
| receive and download files | ✓ | ✓ |
| send files to chosen members | ✓ | ✓ |
| delete own deliveries | ✓ | ✓ |
| delete any delivery | | ✓ |
| add, remove, promote, demote members | | ✓ |

## Removing a member and WebDAV access

Removing a member keeps its public keys with role `removed`, so entries it sent
earlier stay verifiable. All shared keys it knew are replaced and sealed again to
the remaining members. Entries already addressed to the removed user stay
readable for them; new entries are not.

The removed user still knows the WebDAV password. The admin therefore creates
a new app password on the server, revokes the old one and sends the new one to
the remaining members, for example with a new invite.

WebDAV access data (URL, user, app password) is never stored in `sync.json`;
each device keeps its own in its encrypted vault. A member enters new data under
*Settings → Change WebDAV access* (or pastes a new invite); the sync error banner
offers the same when the login fails. New data is saved only after the app
reached the folder through Tor and found this very group there: valid
signatures, the admin key this device trusts (after an admin change, the new
fingerprint from an admin), and the user still a member. A typo or a foreign
folder therefore cannot lock a device out. Files written by earlier versions,
which kept the credentials encrypted in `sync.json`, lose them with the next
change of the member list.

## Local storage

Private keys, the WebDAV configuration, the pinned admin key and the last seen
versions are stored in `groups/<name>/vault.json` in the app support folder,
encrypted with the group's password. Next to it, `folder.txt` holds a SHA-256
hash of the WebDAV folder URL so two local groups cannot share a sync file.
Non-secret settings (language, theme, Tor port) are kept in `settings.json`.

On Tails, the normal data folder is wiped on reboot. The installer therefore
starts the app with `REDCOURIER_DATA_DIR` pointing into the Persistent Storage
(`~/Persistent/programs/redcourier/data`). Received files go to the amnesic
`~/Tor Browser` unless the user chooses to keep them. A copy of the last verified `sync.json` is kept for offline
viewing and is verified again on load. The app locks itself after five minutes
in the background.

On Android and iOS, input fields use the built-in keyboard of RedCourier so
third-party keyboards never see passwords, codes or notes.

## Release integrity

Release packages are signed with an Ed25519 key in the same way as CalSec:

```text
SHA256SUMS        SHA-256 of every file in the package
SHA256SUMS.sig    base64(Ed25519(release key, SHA256SUMS))
<zip>.sig         base64(Ed25519(release key, zip))
<AppImage>.sig    base64(Ed25519(release key, RedCourier-<version>-x86_64.AppImage))
```

The zip is for installing; the separately published AppImage with its
signature is what the in-app updater downloads.

The Tails installer verifies `SHA256SUMS.sig` with the key built into it and
then every file against `SHA256SUMS`. On the first installation it shows the
key's fingerprint, which the user compares with the value below or one from a
trusted contact. The key is then stored in the install folder; an update
signed with a different key is refused unless the user explicitly accepts the
new fingerprint. A package that is signed with a matching key but altered in
any byte fails the check.

What the installer can and cannot protect:

- **Updates** are run with the installed installer and the new package folder
  as argument. The installed copy checks the package against the pinned key,
  so a forged package fails even if it ships its own manipulated installer.
- **Automatic updates** (optional, off by default) work like CalSec's: the app
  asks the release channel for the latest release, downloads
  `RedCourier-<version>-x86_64.AppImage` and its `.sig` from that release
  through Tor on a separate circuit, and verifies the signature over the
  downloaded file with the release key built into the app. Without a
  signature, with a damaged or an invalid one, the file is deleted and nothing
  is installed. Only then is the AppImage run, to unpack itself
  (`--appimage-extract`, Tails has no FUSE) inside the install folder. The
  `app` folder is swapped by renaming, so a failure leaves the installed
  version in place; the previous version is deleted on the next start. On
  Windows (installed with the setup file) the app downloads
  `RedCourier-<version>-windows-x64-setup.exe` and its `.sig` the same way,
  verifies it and runs it silently (`/VERYSILENT /CLOSEAPPLICATIONS`); the
  per-user installer needs no administrator rights, replaces the program and
  starts it again. A copied or self-built Windows program (no uninstaller next
  to it) does not update itself. On Android, an APK installed from GitHub
  downloads `RedCourier-<version>.apk` and its `.sig`, verifies it and hands it
  to the system package installer, which additionally requires the same APK
  signing key as the installed app and the user's confirmation. If the app was
  installed by F-Droid or a store, the in-app update is disabled. The release
  channel is either the GitHub Releases API of the project or a custom
  URL returning the same JSON; it only needs to be trusted for availability,
  not for integrity, because the key comes with the installed app.
- **The first installation** runs the installer from the downloaded package.
  A completely forged package could ship an installer that skips the checks
  and shows the genuine fingerprint. The zip must therefore be verified with
  the published key *before* anything from it is run (see below).

Release key fingerprint (SHA-256 of the DER-encoded public key):

```text
3DAE 4A64 9D09 1510 DC7E 8A39 DB63 6779 16B3 2613 3E51 1EA0 1588 A21B 9714 2CC0
```

Release public key:

```text
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAqM4F702GERqjZ1KhRh6VUnINE4iPyedSiua9RX66v58=
-----END PUBLIC KEY-----
```

To verify a zip by hand:

```bash
base64 -d redcourier-<version>-linux-x86_64.zip.sig > zip.sig.bin
openssl pkeyutl -verify -pubin -inkey release_signing_key.pem -rawin \
  -in redcourier-<version>-linux-x86_64.zip -sigfile zip.sig.bin
```

## Limitations

- **Metadata.** The WebDAV provider sees the size of `sync.json`, the number of
  recipients per entry, creation and expiry times, the sender's user id and
  access times. The file hosts see the size of each part and when it is
  uploaded and downloaded. Tor hides the users' IP addresses, not this
  metadata.
- **File hosts.** Deliveries depend on public services that can delete files
  early, go offline, change their API or block Tor. Spreading parts over
  several hosts helps on upload; once uploaded, a part is only at one host, so
  if it disappears the delivery has to be sent again. Hosts limit how long
  deliveries live (about six days at most).
- **Members are trusted with the file list.** Every member holds the file
  signing key. A malicious member cannot forge or change entries of others (sender
  signatures), but can delete them or re-add old ones that have not expired.
  Anyone with the WebDAV password can delete files anyway.
- **Admins are fully trusted.** An admin can add members, including fake ones,
  and read the member list.
- **No forward secrecy.** Whoever obtains a user's private key can read all
  entries addressed to that user that are still on the server.
- **Trust on first use.** If both channels, the one for the invite and the one
  for the fingerprint, are compromised, the first sync can be subverted.
- **Local password.** The vault is only as strong as the local password. Use a
  long one.
- **Release key.** Whoever holds the private release key can publish packages
  that the installer accepts. Its fingerprint must be checked once over a
  trusted channel; a compromised key has to be replaced and announced the
  same way.
