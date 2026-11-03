# Driving Tunnelblick's engine without Tunnelblick.app

The reverse-engineered interfaces Burrow uses. Evidence and status for each fact: `re/REA-FINDINGS.md`.
Observed against Tunnelblick 8.0 (build 6300) and OpenVPN 2.6.14.

## 1. tunnelblickd

Root launchd daemon `net.tunnelblick.tunnelblick.tunnelblickd`, listening on the Unix stream socket
`/var/run/net.tunnelblick.tunnelblick.tunnelblickd.socket` (mode 0666). One request per connection.

Request: a single write of at most 2046 bytes:

```
openvpnstart: <arg1>\t<arg2>\t…\t<argN>\n
```

No argument may contain a tab or newline. tunnelblickd identifies the caller with `getpeereid` and runs
`/Library/Application Support/Tunnelblick/Tunnelblick.app/Contents/Resources/tunnelblick-helper <args>` on its behalf.
There is no other client authentication; the helper enforces what may be started.

Reply, then the daemon closes the socket:

```
<status> <stdout length> <stderr length>\n<stdout><stderr>\0
```

`status` is the helper's exit status (0 = success). The lengths are `NSString` lengths (UTF-16 units).

Subcommands Burrow uses:

| Request | Purpose |
|---|---|
| `test` | Always succeeds (`0 0 0`). |
| `start <name>.tblk <port> <useScripts> <skipScrSec> <cfgLocCode> <noMonitor> <bitMask> <leasewatch> <openvpnVersion> <mgmtPassword>` | Start OpenVPN as a daemon (see §2). |
| `expectDisconnect 1 <encoded resources path>` | Mark the next disconnect as intended. |
| `kill <pid>` | Kill one OpenVPN process (fallback when the management interface is gone). |
| `printSanitizedConfigurationFile <name>.tblk <cfgLocCode>` | Print the config without inline keys (`burrowctl daemon …`). |

`cfgLocCode` 3 = `/Library/Application Support/Tunnelblick/Shared`, 1 = `…/Tunnelblick/Users/<user>`.
Private configurations (0) are refused, so the config must be installed as Shared, or Tunnelblick must have made
its secured copy under `Users/<user>`.

Path encoding for `expectDisconnect` (also used by `client.down.tunnelblick.sh`): `-` → `--`, `.` → `-D`, `/` → `-S`,
applied to `…/<name>.tblk/Contents/Resources`.

## 2. `start` arguments

What Tunnelblick 8.0 sent for a default TUN config on macOS 27, and what Burrow sends:

```
start office.tblk 63637 0x00000301 0 3 0 0x0210c130 -ptADGNWradsgnw 2.6.14-openssl-3.0.16 <64-char password>
```

| Field | Value | Meaning |
|---|---|---|
| mgtPort | 49152–65535 | Management port; other values are replaced by a free one |
| useScripts | `0x301` | bit 0: Tunnelblick's up/down scripts (DNS, IPv6); bits 8–11: `--verb 3` |
| skipScrSec | `0` | send `--script-security 2` |
| noMonitor | `0` | watch for network-setting changes (`process-network-changes`) |
| bitMask | `0x0210c130` | bits 4, 5, 8, 14, 15, 20, 25 — see REA-FINDINGS §3; bit 14 adds `--management-query-passwords --management-hold` |
| leasewatch | `-ptADGNWradsgnw` | `process-network-changes` options |
| openvpnVersion | target of `Resources/openvpn/default`, minus `openvpn-` | which bundled OpenVPN to run |
| mgmtPassword | ≤ 127 bytes | written as root to `…/Tunnelblick/Mips/<name>.tblk.mip`; OpenVPN's management password |

The helper deletes the configuration's previous OpenVPN logs and writes the new one to
`/Library/Application Support/Tunnelblick/Logs/<encoded config path>.<args>.<port>.openvpn.log` (world-readable).

## 3. OpenVPN management conversation

TCP to `127.0.0.1:<port>`; every command ends with `\r\n`.

```
→ <mgmtPassword>                 (OpenVPN printed "ENTER PASSWORD:" with no newline)
← SUCCESS: password is correct
→ pid / auth-retry interact / state on / state / bytecount 1
← >HOLD:Waiting for hold release:0
→ hold release
← >PASSWORD:Need 'Auth' username/password
→ username "Auth" "<username>"
→ password "Auth" "<password><6-digit TOTP>"
← >STATE:…,CONNECTED,SUCCESS,<tunnel IP>,<server IP>,…
→ forget-passwords                (Burrow only: a later restart asks again instead of replaying a stale code)
…
→ signal SIGTERM                  (disconnect; repeated every second until OpenVPN exits)
```

Escaping inside quotes, as Tunnelblick does it: `\` → `\\`, `"` → `\"`, CR/LF removed; at most 250 bytes per field.
If the server rejects the credentials, `auth-retry interact` makes OpenVPN print
`>PASSWORD:Verification Failed: 'Auth'` and ask again. Burrow answers once more with the next time step's code, then
gives up, so a wrong password can't lock the account. A `static-challenge` config gets
`password "Auth" "SCRV1:<base64 password>:<base64 code>"`.

The server is a firewall appliance that takes the password and code concatenated, which is what Tunnelblick's
login window did when its "security token" box was ticked (`password + token`, no separator).
