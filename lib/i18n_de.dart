// German texts. Keys are the English source texts used in the code.
// test/i18n_test.dart checks that every text has a translation here.

const germanTexts = <String, String>{
  // ── General ──
  'OK': 'OK',
  'Cancel': 'Abbrechen',
  'Close': 'Schließen',
  'Continue': 'Weiter',
  'Copy': 'Kopieren',
  'Copied to clipboard': 'In die Zwischenablage kopiert',
  'Create': 'Erstellen',
  'Delete': 'Löschen',
  'Deleted': 'Gelöscht',
  'Deleting…': 'Wird gelöscht…',
  'Done': 'Fertig',
  'Download': 'Herunterladen',
  'Loading…': 'Wird geladen…',
  'Lock': 'Sperren',
  'Publish': 'Veröffentlichen',
  'Publishing…': 'Wird veröffentlicht…',
  'Remove': 'Entfernen',
  'Retry': 'Erneut versuchen',
  'Verify': 'Prüfen',
  'Settings': 'Einstellungen',
  'Language': 'Sprache',
  'RedCourier {version}': 'RedCourier {version}',
  'admin': 'Admin',
  'member': 'Mitglied',
  'new': 'neu',
  'you': 'du',
  '{n} new': '{n} neu',

  // ── Time ──
  '1 day': '1 Tag',
  '{n} days': '{n} Tage',
  'expired': 'abgelaufen',
  'expires in 1 day': 'läuft in 1 Tag ab',
  'expires in {n} days': 'läuft in {n} Tagen ab',
  'expires in {n} h': 'läuft in {n} Std. ab',
  'expires in {n} min': 'läuft in {n} Min. ab',

  // ── Profiles and setup ──
  'Welcome to RedCourier': 'Willkommen bei RedCourier',
  'Identifier (name or handle)': 'Identifier (Name oder Kürzel)',
  'Password': 'Passwort',
  'Repeat password': 'Passwort wiederholen',
  'Creating keys…': 'Schlüssel werden erzeugt…',
  'The password needs at least {n} characters.': 'Das Passwort braucht mindestens {n} Zeichen.',
  'The passwords do not match.': 'Die Passwörter stimmen nicht überein.',
  'Use letters, digits, spaces, dots, dashes or underscores, starting with a letter or digit.':
      'Erlaubt sind Buchstaben, Ziffern, Leerzeichen, Punkte, Binde- und Unterstriche. Der Name muss mit einem Buchstaben oder einer Ziffer beginnen.',
  'Please enter an identifier.': 'Bitte gib einen Identifier ein.',
  'At most 64 characters.': 'Höchstens 64 Zeichen.',
  'Control characters are not allowed.': 'Steuerzeichen sind nicht erlaubt.',
  'Unlock': 'Entsperren',
  'Wrong password.': 'Falsches Passwort.',
  'The local vault file is damaged.': 'Die lokale Schlüsseldatei ist beschädigt.',

  // ── Joining and creating groups ──
  'Join an existing group': 'Einer bestehenden Gruppe beitreten',
  '1. Send your join request to an admin of the group.':
      '1. Schicke deine Beitrittsanfrage an einen Admin der Gruppe.',
  'Your identifier: {name}': 'Dein Identifier: {name}',
  'Your user id: {id}': 'Deine Benutzer-ID: {id}',
  'Show join request': 'Beitrittsanfrage anzeigen',
  'Your join request': 'Deine Beitrittsanfrage',
  'It contains only your identifier and public keys. The admin should compare your user id ({id}) with you.':
      'Sie enthält nur deinen Identifier und deine öffentlichen Schlüssel. Der Admin sollte deine Benutzer-ID ({id}) mit dir abgleichen.',
  '2. When the admin has added you, paste the invite you received.':
      '2. Wenn der Admin dich hinzugefügt hat, füge die Einladung ein, die du bekommen hast.',
  'Join group': 'Gruppe beitreten',
  'Use a WebDAV folder, for example a Nextcloud folder. Use an app password, not your main password.\nExample URL: https://cloud.example.com/remote.php/dav/files/USER/redcourier/':
      'Nutze einen WebDAV-Ordner, zum Beispiel einen Nextcloud-Ordner. Verwende ein App-Passwort, nicht dein Hauptpasswort.\nBeispiel-URL: https://cloud.example.com/remote.php/dav/files/USER/redcourier/',
  'WebDAV folder URL': 'URL des WebDAV-Ordners',
  'WebDAV username': 'WebDAV-Benutzername',
  'WebDAV app password': 'WebDAV-App-Passwort',
  'Create group': 'Gruppe erstellen',
  'Create a new group?': 'Neue Gruppe erstellen?',
  'RedCourier will create sync.json in\n{url}\n\nUse an empty folder that only your group can access. You become the admin.':
      'RedCourier legt sync.json an in\n{url}\n\nNutze einen leeren Ordner, auf den nur deine Gruppe Zugriff hat. Du wirst Admin.',
  'Please enter the WebDAV username.': 'Bitte gib den WebDAV-Benutzernamen ein.',
  'Please enter a full URL.': 'Bitte gib eine vollständige URL ein.',
  'Only http(s) URLs are supported.': 'Nur http(s)-URLs werden unterstützt.',
  'Not a RedCourier invite.': 'Das ist keine RedCourier-Einladung.',
  'Corrupted invite.': 'Die Einladung ist beschädigt.',
  'Invalid URL.': 'Ungültige URL.',
  'Not a RedCourier join request.': 'Das ist keine RedCourier-Beitrittsanfrage.',
  'Corrupted join request.': 'Die Beitrittsanfrage ist beschädigt.',
  'Invalid keys.': 'Ungültige Schlüssel.',

  // ── Home ──
  'Inbox': 'Posteingang',
  'Sent': 'Gesendet',
  'Send': 'Senden',
  'Sync': 'Synchronisieren',
  'Members': 'Mitglieder',
  '1 new delivery': '1 neue Lieferung',
  '{n} new deliveries': '{n} neue Lieferungen',
  'Up to date': 'Alles aktuell',
  'The admin updated the WebDAV credentials.': 'Der Admin hat die WebDAV-Zugangsdaten aktualisiert.',
  'Sync failed: {reason}': 'Synchronisieren fehlgeschlagen: {reason}',
  'Group key changed': 'Gruppenschlüssel geändert',
  'Fingerprint from your admin': 'Fingerprint von deinem Admin',
  'The fingerprint does not match. The update was not accepted.':
      'Der Fingerprint stimmt nicht überein. Die Änderung wurde nicht übernommen.',
  'Saved to {path}': 'Gespeichert unter {path}',
  'Download failed: {reason}': 'Download fehlgeschlagen: {reason}',
  'Delete delivery?': 'Lieferung löschen?',
  'Removed from your inbox': 'Aus deinem Posteingang entfernt',
  'Entries with an invalid signature were hidden: {n}': 'Einträge mit ungültiger Signatur ausgeblendet: {n}',
  'No deliveries for you yet.': 'Noch keine Lieferungen für dich.',
  'You have not sent anything yet.': 'Du hast noch nichts gesendet.',
  'To {names}': 'An {names}',
  'From {name}': 'Von {name}',
  'Remove from my inbox': 'Aus meinem Posteingang entfernen',
  'Delete for everyone': 'Für alle löschen',

  // ── Sending ──
  'Send files': 'Dateien senden',
  'Recipients': 'Empfänger',
  'Search identifier': 'Identifier suchen',
  'No other members yet. Ask an admin to add people.':
      'Noch keine anderen Mitglieder. Bitte einen Admin, Leute hinzuzufügen.',
  'Files': 'Dateien',
  'Choose files': 'Dateien auswählen',
  'Add more files': 'Weitere Dateien hinzufügen',
  'Details': 'Details',
  'Note (optional, encrypted)': 'Notiz (optional, verschlüsselt)',
  'Delete automatically after': 'Automatisch löschen nach',
  'Send to {n} recipient(s)': 'An {n} Empfänger senden',
  'Choose at least one recipient.': 'Wähle mindestens einen Empfänger.',
  'Choose at least one file.': 'Wähle mindestens eine Datei.',
  'Preparing…': 'Wird vorbereitet…',
  'Sending failed: {reason}': 'Senden fehlgeschlagen: {reason}',
  'At most {n} files.': 'Höchstens {n} Dateien.',
  'The note is too long.': 'Die Notiz ist zu lang.',
  'A recipient is no longer a member of the group.': 'Ein Empfänger ist kein Mitglied der Gruppe mehr.',

  // ── Members ──
  'You': 'Du',
  'User id {id} · {role}': 'Benutzer-ID {id} · {role}',
  'Group fingerprint': 'Gruppen-Fingerprint',
  'New group fingerprint': 'Neuer Gruppen-Fingerprint',
  'My join request': 'Meine Beitrittsanfrage',
  'Invite': 'Einladung',
  'Members: {n}': 'Mitglieder: {n}',
  'Add member': 'Mitglied hinzufügen',
  'Paste the join request the new member sent you.':
      'Füge die Beitrittsanfrage ein, die dir das neue Mitglied geschickt hat.',
  'Join request (RCJOIN2:…)': 'Beitrittsanfrage (RCJOIN2:…)',
  'Add {name}?': '{name} hinzufügen?',
  'Compare this user id with the new member before adding them:':
      'Gleiche diese Benutzer-ID mit dem neuen Mitglied ab, bevor du es hinzufügst:',
  'Add as admin': 'Als Admin hinzufügen',
  'Add as member': 'Als Mitglied hinzufügen',
  'Adding member…': 'Mitglied wird hinzugefügt…',
  '{name} was added': '{name} wurde hinzugefügt',
  'Make admin': 'Zum Admin machen',
  'Remove admin rights': 'Admin-Rechte entziehen',
  'Remove from group': 'Aus der Gruppe entfernen',
  'Remove {name}?': '{name} entfernen?',
  'All shared group keys are replaced, so {name} can no longer read the member list or sign changes. Files already sent to {name} stay readable for them.':
      'Alle gemeinsamen Gruppenschlüssel werden ersetzt. Danach kann {name} die Mitgliederliste nicht mehr lesen und keine Änderungen mehr signieren. Dateien, die bereits an {name} gesendet wurden, bleiben für {name} lesbar.',
  'Because {name} is an admin, the group fingerprint changes and every member has to confirm the new one.':
      'Weil {name} Admin ist, ändert sich der Gruppen-Fingerprint, und alle Mitglieder müssen den neuen bestätigen.',
  'Afterwards, change the WebDAV password: publish new credentials in Settings, wait until everyone has synced, then change the password on the server.':
      'Ändere danach das WebDAV-Passwort: Veröffentliche neue Zugangsdaten in den Einstellungen, warte, bis alle synchronisiert haben, und ändere dann das Passwort auf dem Server.',
  'Removing member and rotating keys…': 'Mitglied wird entfernt, Schlüssel werden ersetzt…',
  '{name} was removed': '{name} wurde entfernt',
  'The admin key is replaced. The group fingerprint changes and every member has to confirm the new one.':
      'Der Admin-Schlüssel wird ersetzt. Der Gruppen-Fingerprint ändert sich, und alle Mitglieder müssen den neuen bestätigen.',
  'Updating role…': 'Rolle wird geändert…',
  'Appearance': 'Darstellung',
  'System': 'System',
  'Light': 'Hell',
  'Dark': 'Dunkel',
  'Tor': 'Tor',
  'All connections go through Tor. Without Tor, RedCourier does not connect at all. Tails starts Tor automatically. On Windows, start Tor Browser or the Tor service; on Android, start Orbot.':
      'Alle Verbindungen laufen über Tor. Ohne Tor baut RedCourier gar keine Verbindung auf. Tails startet Tor automatisch. Unter Windows starte den Tor Browser oder den Tor-Dienst, unter Android starte Orbot.',
  'Find Tor automatically': 'Tor automatisch finden',
  'Tries port 9050 (Tails, Tor service, Orbot) and 9150 (Tor Browser).':
      'Probiert Port 9050 (Tails, Tor-Dienst, Orbot) und 9150 (Tor Browser).',
  'Tor SOCKS port on 127.0.0.1': 'Tor-SOCKS-Port auf 127.0.0.1',
  'Please enter a port between 1 and 65535.': 'Bitte gib einen Port zwischen 1 und 65535 ein.',
  'Test Tor connection': 'Tor-Verbindung testen',
  'Connected through Tor (port {port}, exit {ip}).': 'Über Tor verbunden (Port {port}, Exit {ip}).',
  'Lock now': 'Jetzt sperren',
  'Group': 'Gruppe',
  'WebDAV folder': 'WebDAV-Ordner',
  'Username: {name}': 'Benutzername: {name}',
  'Publish new WebDAV credentials': 'Neue WebDAV-Zugangsdaten veröffentlichen',
  '1. Create a new app password on the server, keep the old one active.\n2. Publish it here. It is stored encrypted in sync.json.\n3. Wait until all members have synced.\n4. Revoke the old password on the server.':
      '1. Erstelle auf dem Server ein neues App-Passwort und lass das alte aktiv.\n2. Veröffentliche es hier. Es wird verschlüsselt in sync.json gespeichert.\n3. Warte, bis alle Mitglieder synchronisiert haben.\n4. Widerrufe das alte Passwort auf dem Server.',
  'Username': 'Benutzername',
  'New app password': 'Neues App-Passwort',
  'Username and password are required.': 'Benutzername und Passwort sind erforderlich.',
  'Published. Members receive the new credentials on their next sync.':
      'Veröffentlicht. Die Mitglieder erhalten die neuen Zugangsdaten bei ihrer nächsten Synchronisierung.',
  'Delete downloaded files': 'Heruntergeladene Dateien löschen',
  'Delete downloaded files?': 'Heruntergeladene Dateien löschen?',
  'This deletes everything in\n{path}': 'Damit wird alles gelöscht in\n{path}',
  'Downloads deleted.': 'Downloads gelöscht.',
  'Could not delete: {reason}': 'Löschen fehlgeschlagen: {reason}',

  // ── Sync and server errors ──
  'No sync.json found in the WebDAV folder.': 'Im WebDAV-Ordner wurde keine sync.json gefunden.',
  'sync.json is not valid JSON.': 'sync.json ist kein gültiges JSON.',
  'This is not a RedCourier sync file.': 'Das ist keine RedCourier-Sync-Datei.',
  'Unsupported sync format version. Please update the app.':
      'Diese Version des Sync-Formats wird nicht unterstützt. Bitte aktualisiere die App.',
  'sync.json is malformed ({what}).': 'sync.json ist fehlerhaft ({what}).',
  'Signing keys missing.': 'Signaturschlüssel fehlen.',
  'The user list signature is invalid. The file may have been tampered with.':
      'Die Signatur der Benutzerliste ist ungültig. Die Datei wurde möglicherweise manipuliert.',
  'The file list signature is invalid. The file may have been tampered with.':
      'Die Signatur der Dateiliste ist ungültig. Die Datei wurde möglicherweise manipuliert.',
  'sync.json contains an invalid user id.': 'sync.json enthält eine ungültige Benutzer-ID.',
  'sync.json contains an invalid public key.': 'sync.json enthält einen ungültigen öffentlichen Schlüssel.',
  'A user id does not match its keys.': 'Eine Benutzer-ID passt nicht zu ihren Schlüsseln.',
  'sync.json contains an unknown role.': 'sync.json enthält eine unbekannte Rolle.',
  'Confirm the group fingerprint before the first sync.':
      'Bestätige vor der ersten Synchronisierung den Gruppen-Fingerprint.',
  'The group signing key changed. Confirm the new fingerprint with your admin.':
      'Der Signaturschlüssel der Gruppe hat sich geändert. Bestätige den neuen Fingerprint mit deinem Admin.',
  'You are not (or no longer) a member of this group. Ask an admin to add you with your join request.':
      'Du bist (noch) kein Mitglied dieser Gruppe oder nicht mehr. Bitte einen Admin, dich mit deiner Beitrittsanfrage hinzuzufügen.',
  'The server returned an older version of sync.json than this device has already seen. This can be a replay attack. Nothing was changed.':
      'Der Server hat eine ältere Version von sync.json geliefert, als dieses Gerät schon kennt. Das kann ein Replay-Angriff sein. Es wurde nichts geändert.',
  'The file signing key does not match. Ask an admin to re-add you.':
      'Der Signaturschlüssel für Dateien passt nicht. Bitte einen Admin, dich erneut hinzuzufügen.',
  'The admin signing key does not match.': 'Der Admin-Signaturschlüssel passt nicht.',
  'sync.json disappeared from the server.': 'sync.json ist vom Server verschwunden.',
  'Only admins can change members.': 'Nur Admins können Mitglieder ändern.',
  'Only admins can manage members.': 'Nur Admins können Mitglieder verwalten.',
  'sync.json keeps changing. Please try again in a moment.':
      'sync.json ändert sich ständig. Bitte versuche es gleich noch einmal.',
  'Only the sender or an admin can delete this.': 'Nur der Absender oder ein Admin kann das löschen.',
  '{name} is already a member.': '{name} ist bereits Mitglied.',
  'Another member already uses the identifier "{name}".':
      'Ein anderes Mitglied verwendet bereits den Identifier „{name}“.',
  'You cannot remove yourself.': 'Du kannst dich nicht selbst entfernen.',
  'You cannot change your own role.': 'Du kannst deine eigene Rolle nicht ändern.',
  'User not found.': 'Benutzer nicht gefunden.',
  'This folder already contains a RedCourier group. Join it instead.':
      'In diesem Ordner gibt es schon eine RedCourier-Gruppe. Tritt ihr stattdessen bei.',
  'sync.json was changed by someone else.': 'sync.json wurde von jemand anderem geändert.',
  'WebDAV login failed (401). Check username and password.':
      'WebDAV-Anmeldung fehlgeschlagen (401). Prüfe Benutzername und Passwort.',
  'Access denied (403) while {what}.': 'Zugriff verweigert (403) beim {what}.',
  'Not found (404) while {what}. Check the folder URL.':
      'Nicht gefunden (404) beim {what}. Prüfe die Ordner-URL.',
  'Storage is full (507) while {what}.': 'Speicher voll (507) beim {what}.',
  'Unexpected server response ({status}) while {what}.': 'Unerwartete Serverantwort ({status}) beim {what}.',
  'downloading sync.json': 'Herunterladen von sync.json',
  'uploading sync.json': 'Hochladen von sync.json',
  'Connection failed: {reason}': 'Verbindung fehlgeschlagen: {reason}',
  'TLS handshake failed. Check the URL and certificate.':
      'TLS-Handshake fehlgeschlagen. Prüfe URL und Zertifikat.',
  'HTTP error: {reason}': 'HTTP-Fehler: {reason}',
  'Connection timed out.': 'Zeitüberschreitung der Verbindung.',

  // ── Tor ──
  'Tor is not reachable on {ports}. Start Tor first: Tails does this automatically, on Windows start Tor Browser or the Tor service, on Android start Orbot.':
      'Tor ist unter {ports} nicht erreichbar. Starte zuerst Tor: Tails macht das automatisch, unter Windows starte den Tor Browser oder den Tor-Dienst, unter Android starte Orbot.',
  'The connection does not go through Tor.': 'Die Verbindung läuft nicht über Tor.',
  'Tor check failed: {reason}': 'Tor-Prüfung fehlgeschlagen: {reason}',

  // ── Cryptography ──
  'Expected base64 string.': 'Base64-Text erwartet.',
  'Invalid base64 data.': 'Ungültige Base64-Daten.',
  'Missing encrypted data.': 'Verschlüsselte Daten fehlen.',
  'Malformed encrypted data.': 'Fehlerhafte verschlüsselte Daten.',
  'Decryption failed.': 'Entschlüsselung fehlgeschlagen.',
  'ML-KEM seed must be 64 bytes.': 'Der ML-KEM-Seed muss 64 Bytes lang sein.',
  'Invalid recipient key.': 'Ungültiger Empfängerschlüssel.',
  'Missing sealed data.': 'Versiegelte Daten fehlen.',
  'Malformed sealed data.': 'Fehlerhafte versiegelte Daten.',
  'Not addressed to this key.': 'Nicht an diesen Schlüssel adressiert.',
  'Not a RedCourier file.': 'Das ist keine RedCourier-Datei.',
  'Invalid chunk size.': 'Ungültige Blockgröße.',
  'File is truncated.': 'Die Datei ist unvollständig.',
  'The file was modified or the key is wrong.': 'Die Datei wurde verändert oder der Schlüssel ist falsch.',
  // ── Groups on this device ──
  'Add group': 'Gruppe hinzufügen',
  'Group {name}': 'Gruppe {name}',
  'Group name (only on this device)': 'Gruppenname (nur auf diesem Gerät)',
  'e.g. Work or Family': 'z. B. Arbeit oder Familie',
  'Password for this group': 'Passwort für diese Gruppe',
  'Open this group at start': 'Diese Gruppe beim Start öffnen',
  'Switch group': 'Gruppe wechseln',
  'Start a new group as admin': 'Neue Gruppe als Admin starten',
  'Delete from this device': 'Von diesem Gerät löschen',
  'Delete this group from this device': 'Diese Gruppe von diesem Gerät löschen',
  'Forgot password? Delete this group from this device': 'Passwort vergessen? Diese Gruppe von diesem Gerät löschen',
  'Delete group "{name}" from this device?': 'Gruppe „{name}“ von diesem Gerät löschen?',
  'This deletes your identity, keys and the local data of this group from this device. Nothing on the server changes. To use the group again you need a new join request. Downloaded files are not deleted.':
      'Damit werden deine Identität, deine Schlüssel und die lokalen Daten dieser Gruppe von diesem Gerät gelöscht. Auf dem Server ändert sich nichts. Um die Gruppe wieder zu nutzen, brauchst du eine neue Beitrittsanfrage. Heruntergeladene Dateien bleiben erhalten.',
  'A group with this name already exists on this device.': 'Auf diesem Gerät gibt es schon eine Gruppe mit diesem Namen.',
  'Every group on this device has its own identity, password and sync file. Members of one group never see your other groups.':
      'Jede Gruppe auf diesem Gerät hat eine eigene Identität, ein eigenes Passwort und eine eigene Sync-Datei. Mitglieder einer Gruppe sehen deine anderen Gruppen nie.',
  'The group "{name}" on this device already uses this WebDAV folder. Every group needs its own folder.':
      'Die Gruppe „{name}“ auf diesem Gerät nutzt diesen WebDAV-Ordner schon. Jede Gruppe braucht einen eigenen Ordner.',

  // ── Updates ──
  'Updates': 'Updates',
  'Update {version}': 'Update {version}',
  'Check for updates at start': 'Beim Start nach Updates suchen',
  'Downloads go through Tor and are only installed with a valid release signature.':
      'Downloads laufen über Tor und werden nur mit gültiger Release-Signatur installiert.',
  'Install automatically': 'Automatisch installieren',
  'Only notify': 'Nur benachrichtigen',
  'Official releases (GitHub)': 'Offizielle Releases (GitHub)',
  'Custom channel': 'Eigener Kanal',
  'Channel URL (GitHub-compatible release JSON)': 'Kanal-URL (GitHub-kompatibles Release-JSON)',
  'Check now': 'Jetzt prüfen',
  'Checking for updates…': 'Suche nach Updates…',
  'RedCourier is up to date.': 'RedCourier ist aktuell.',
  'Downloading update {version}…': 'Update {version} wird heruntergeladen…',
  'Signature valid. Installing…': 'Signatur gültig. Wird installiert…',
  'Update installed. Restarting…': 'Update installiert. Neustart…',
  'Update failed: {reason}': 'Update fehlgeschlagen: {reason}',
  'Update {version} is available.': 'Update {version} ist verfügbar.',
  'Later': 'Später',
  'Install now': 'Jetzt installieren',
  'Updates are only available for installed versions.':
      'Updates gibt es nur für Versionen, die mit dem Installer installiert wurden.',
  'The release key is not an Ed25519 public key.': 'Der Release-Schlüssel ist kein öffentlicher Ed25519-Schlüssel.',
  'Update URLs must use https.': 'Update-URLs müssen https verwenden.',
  'The update server answered with {status}.': 'Der Update-Server antwortete mit {status}.',
  'The update channel did not return a release.': 'Der Update-Kanal hat kein Release geliefert.',
  'The release has no signature. The update was not installed.':
      'Das Release hat keine Signatur. Das Update wurde nicht installiert.',
  'The release signature is damaged.': 'Die Release-Signatur ist beschädigt.',
  'The download is too large.': 'Der Download ist zu groß.',
  'The signature of the update is invalid. It was not installed.':
      'Die Signatur des Updates ist ungültig. Es wurde nicht installiert.',
  'The update package is incomplete.': 'Das Update-Paket ist unvollständig.',
  // ── File hosts ──
  'Packing files…': 'Dateien werden gepackt…',
  'Encrypting…': 'Wird verschlüsselt…',
  'Decrypting…': 'Wird entschlüsselt…',
  'Unpacking…': 'Wird entpackt…',
  'Part {i}: uploading to {host}…': 'Teil {i}: wird zu {host} hochgeladen…',
  'No hosting service accepts a delivery of this size.': 'Kein Datei-Anbieter nimmt eine Lieferung dieser Größe an.',
  'The part is too large for {host}.': 'Der Teil ist zu groß für {host}.',
  '{host} answered with an unexpected reply.': '{host} hat unerwartet geantwortet.',
  'Tor could not connect to {host}: {reason}': 'Tor konnte keine Verbindung zu {host} herstellen: {reason}',
  'Part {i}/{n}: downloading from {host}…': 'Teil {i}/{n}: wird von {host} geladen…',
  'Download {n} files': '{n} Dateien herunterladen',
  'No hosting service accepted part {i}. Last error: {reason}':
      'Kein Filesharing-Dienst hat Teil {i} angenommen. Letzter Fehler: {reason}',
  'No hosting service keeps files that long. Choose a shorter time.':
      'Kein Filesharing-Dienst bewahrt Dateien so lange auf. Wähle eine kürzere Zeit.',
  'Part {i} was changed at the hosting service.': 'Teil {i} wurde beim Filesharing-Dienst verändert.',
  'A part is stored at an unknown hosting service ({host}).':
      'Ein Teil liegt bei einem unbekannten Filesharing-Dienst ({host}).',
  'A download link points to an unexpected address.': 'Ein Download-Link zeigt auf eine unerwartete Adresse.',
  'A downloaded part is larger than expected.': 'Ein heruntergeladener Teil ist größer als erwartet.',
  'A downloaded part is not a RedCourier part.': 'Ein heruntergeladener Teil ist kein RedCourier-Teil.',
  'The file is no longer available at the hosting service.':
      'Die Datei ist beim Filesharing-Dienst nicht mehr verfügbar.',
  'The hosting service answered with {status}.': 'Der Filesharing-Dienst antwortete mit {status}.',
  'Upload to {host} failed ({status}).': 'Upload zu {host} fehlgeschlagen ({status}).',
  'The delivery is removed for all recipients. Where the hosting service allows it, the uploaded files are deleted too.':
      'Die Lieferung wird für alle Empfänger entfernt. Wo der Filesharing-Dienst es erlaubt, werden auch die hochgeladenen Dateien gelöscht.',
  // ── Start: join or create ──
  'RedCourier sends end-to-end encrypted files to the members of your group. The files are stored encrypted at file sharing services, the group itself in a shared WebDAV folder, for example on Nextcloud. All traffic goes through Tor.':
      'RedCourier sendet Ende-zu-Ende-verschlüsselte Dateien an die Mitglieder deiner Gruppe. Die Dateien liegen verschlüsselt bei Filesharing-Diensten, die Gruppe selbst in einem gemeinsamen WebDAV-Ordner, zum Beispiel auf Nextcloud. Der gesamte Datenverkehr läuft über Tor.',
  'Join a group': 'Einer Gruppe beitreten',
  'An admin adds you. You send them your join request and get an invite back.':
      'Ein Admin fügt dich hinzu. Du schickst ihm deine Beitrittsanfrage und bekommst eine Einladung zurück.',
  'Start a new group': 'Neue Gruppe gründen',
  'You become the admin. You need an empty WebDAV folder, for example on Nextcloud.':
      'Du wirst Admin. Du brauchst einen leeren WebDAV-Ordner, zum Beispiel auf Nextcloud.',
  'Back': 'Zurück',
  'Your identifier is how other members find you when they send files. Your private keys never leave this device and are protected by the password below. The group name is only shown on this device.':
      'Über deinen Identifier finden dich andere Mitglieder, wenn sie dir Dateien schicken. Deine privaten Schlüssel verlassen dieses Gerät nie und sind durch das Passwort unten geschützt. Der Gruppenname ist nur auf diesem Gerät sichtbar.',
  'Cancel sending':
      'Senden abbrechen',
  'Cancelled.':
      'Abgebrochen.',
  'Download paused. Finished parts are kept, you can resume later.':
      'Download angehalten. Fertige Teile bleiben erhalten, du kannst später fortsetzen.',
  'Enter the group fingerprint your admin sent you over a second channel.':
      'Gib den Gruppen-Fingerprint ein, den dir dein Admin über einen zweiten Kanal geschickt hat.',
  'Finished parts are kept, you can resume later.':
      'Fertige Teile bleiben erhalten, du kannst später fortsetzen.',
  'Invite (RCINVITE2:…)':
      'Einladung (RCINVITE2:…)',
  'New deliveries':
      'Neue Lieferungen',
  'Notifications':
      'Benachrichtigungen',
  'Notify about new deliveries':
      'Über neue Lieferungen benachrichtigen',
  'RedCourier group fingerprint:\n{fp}':
      'RedCourier-Gruppen-Fingerprint:\n{fp}',
  'Resume download ({done}/{n} parts)':
      'Download fortsetzen ({done}/{n} Teile)',
  'Scan QR code':
      'QR-Code scannen',
  'Scan group fingerprint':
      'Gruppen-Fingerprint scannen',
  'Scan invite':
      'Einladung scannen',
  'Send this fingerprint over a different channel than the invite: by e-mail (copy the text), or let the new member scan the QR code with the Android app. Members can also compare it at any time to make sure nobody swapped the group keys.':
      'Schicke diesen Fingerprint über einen anderen Kanal als die Einladung: per E-Mail (Text kopieren) oder lass das neue Mitglied den QR-Code mit der Android-App scannen. Mitglieder können ihn auch jederzeit vergleichen, um sicherzugehen, dass niemand die Gruppenschlüssel ausgetauscht hat.',
  'Send this fingerprint to every member over a trusted channel: by e-mail (copy the text), or let them scan the QR code with the Android app. They need it to accept the change.':
      'Schicke diesen Fingerprint über einen vertrauenswürdigen Kanal an alle Mitglieder: per E-Mail (Text kopieren) oder lass sie den QR-Code mit der Android-App scannen. Sie brauchen ihn, um die Änderung anzunehmen.',
  'Sending cancelled. Nothing was published.':
      'Senden abgebrochen. Es wurde nichts veröffentlicht.',
  'Step 1 of 2: send this invite to the new member, for example over a messenger. It contains the WebDAV access data.\nStep 2: send the group fingerprint over a different channel (e-mail, or the QR code for the Android app). Someone who reads only one channel cannot lead the new member into a fake group.':
      'Schritt 1 von 2: Schicke diese Einladung an das neue Mitglied, zum Beispiel per Messenger. Sie enthält die WebDAV-Zugangsdaten.\nSchritt 2: Schicke den Gruppen-Fingerprint über einen anderen Kanal (E-Mail oder QR-Code für die Android-App). Wer nur einen Kanal mitliest, kann das neue Mitglied nicht in eine falsche Gruppe locken.',
  'Stop download':
      'Download anhalten',
  'The admin signing key of this group has changed. This happens when an admin is removed or demoted, but it can also mean someone tampered with the server.\n\nAsk your admin for the new fingerprint over a trusted channel (e-mail, or scan the QR code on their screen) and enter it here.':
      'Der Admin-Signaturschlüssel dieser Gruppe hat sich geändert. Das passiert, wenn ein Admin entfernt oder herabgestuft wird, kann aber auch bedeuten, dass jemand den Server manipuliert hat.\n\nLass dir den neuen Fingerprint von deinem Admin über einen vertrauenswürdigen Kanal geben (E-Mail oder QR-Code auf dem Bildschirm des Admins scannen) und gib ihn hier ein.',
  'The camera is not available. Allow camera access in the system settings or enter the code by hand.':
      'Die Kamera ist nicht verfügbar. Erlaube den Kamerazugriff in den Systemeinstellungen oder gib den Code von Hand ein.',
  'The group does not match the fingerprint you entered. Do not join. Someone may have changed the invite or the server. Contact your admin over another channel.\nFound: {fp}':
      'Die Gruppe passt nicht zum eingegebenen Fingerprint. Tritt nicht bei. Möglicherweise hat jemand die Einladung oder den Server verändert. Kontaktiere deinen Admin über einen anderen Kanal.\nGefunden: {fp}',
  'This invite is from an older version. Ask your admin for a new one.':
      'Diese Einladung stammt aus einer älteren Version. Bitte deinen Admin um eine neue.',
  'This is not a complete group fingerprint (64 characters 0-9 and A-F).':
      'Das ist kein vollständiger Gruppen-Fingerprint (64 Zeichen 0-9 und A-F).',
  'While a group is unlocked, RedCourier syncs every {n} minutes and shows a notification without sender or group name. When the app is closed or locked, nothing is checked.':
      'Solange eine Gruppe entsperrt ist, synchronisiert RedCourier alle {n} Minuten und zeigt eine Benachrichtigung ohne Absender oder Gruppennamen. Ist die App geschlossen oder gesperrt, wird nichts geprüft.',
  '3. Enter the group fingerprint. Your admin sends it over a second channel: by e-mail, or you scan the QR code on their screen.':
      '3. Gib den Gruppen-Fingerprint ein. Dein Admin schickt ihn über einen zweiten Kanal: per E-Mail, oder du scannst den QR-Code auf dem Bildschirm deines Admins.',
  'You can simply try again. If the group was already stored on the server, this device recognizes it as its own and takes it over.':
      'Du kannst es einfach noch einmal versuchen. Falls die Gruppe schon auf dem Server gespeichert wurde, erkennt dieses Gerät sie als eigene und übernimmt sie.',
  'Connected through Tor via torsocks (exit {ip}).': 'Über Tor verbunden, per torsocks (Exit {ip}).',
  'Started with torsocks: torsocks routes all connections into Tor. All groups share its circuits. Start RedCourier without torsocks to get separate circuits per group.':
      'Mit torsocks gestartet: torsocks leitet alle Verbindungen in Tor. Alle Gruppen teilen sich seine Verbindungen. Starte RedCourier ohne torsocks, damit jede Gruppe eigene Tor-Verbindungen bekommt.',
  'Make {name} an admin?':
      '{name} zum Admin machen?',
  'Admins can add and remove members, make others admins and take admin rights away, also from you. The group fingerprint stays the same.':
      'Admins können Mitglieder hinzufügen und entfernen, andere zu Admins machen und Admin-Rechte entziehen, auch dir. Der Gruppen-Fingerprint bleibt gleich.',
  'Remove admin rights from {name}?':
      '{name} die Admin-Rechte entziehen?',
  '{name} is now an admin':
      '{name} ist jetzt Admin',
  'Only one admin':
      'Nur ein Admin',
  'You are the only admin. If you lose this device or forget its password, nobody can manage the group any more. Make a second member admin (menu next to the member).':
      'Du bist der einzige Admin. Verlierst du dieses Gerät oder vergisst das Passwort, kann niemand mehr die Gruppe verwalten. Mach ein zweites Mitglied zum Admin (Menü neben dem Mitglied).',
  'Blocked a direct connection to {target}. RedCourier only connects through Tor.':
      'Direkte Verbindung zu {target} blockiert. RedCourier verbindet sich nur über Tor.',
  'The update could not be unpacked.': 'Das Update konnte nicht entpackt werden.',
  'The update could not be installed. The installed version was kept.':
      'Das Update konnte nicht installiert werden. Die installierte Version bleibt erhalten.',
  'Allow RedCourier to install apps (the settings page just opened), then try again.':
      'Erlaube RedCourier, Apps zu installieren (die Einstellungsseite wurde gerade geöffnet), und versuche es dann noch einmal.',
  'Confirm the installation in the Android dialog, then open RedCourier again.':
      'Bestätige die Installation im Android-Dialog und öffne RedCourier danach wieder.',
};
