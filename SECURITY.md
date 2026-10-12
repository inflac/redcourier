# Security Policy

## Supported Versions

Only the latest release receives security fixes.

## Reporting a Vulnerability

Please report vulnerabilities privately via
[GitHub Security Advisories](https://github.com/inflac/redcourier/security/advisories/new),
not as public issues. Include the affected version and platform, what an
attacker needs, and what they gain. Do not include invites, keys or
`sync.json` files of groups in use.

Of particular interest:

- traffic bypassing Tor or DNS leaks
- breaking the encryption or signatures of `sync.json`, deliveries or releases
- a WebDAV server, file host or removed member reading or forging data
- weaknesses in the updater or the Tails installer

Confirmed issues are fixed in a new release, and reporters are credited if
they wish. The design and its known limitations are described in
[WHITEPAPER.md](WHITEPAPER.md).
