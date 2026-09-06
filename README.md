# linux-toolbox

Bash tools built to production habits. Current tool: an SSL/TLS certificate
expiry checker with monitoring-grade exit codes. More scripts (Linux internals
inspector, log analyzer) coming to the same repo.

---

## check-certs.sh — SSL certificate expiry checker

Checks every domain in `scripts/domains.txt` and reports how many days remain
before its TLS certificate expires, with warning and critical thresholds.
Expired or unreachable certificates are flagged as critical.

Certificate expiry is one of the most common *entirely preventable* causes of
production outages: the certificate quietly ages, nobody is watching, and one
morning every browser shows a red warning and every API client refuses to
connect. This tool is the guardrail — run it on a schedule and expiry can never
surprise you.

### Usage

```bash
./scripts/check-certs.sh                # default thresholds: warn <30d, critical <7d
./scripts/check-certs.sh 45 14          # custom thresholds: warn <45d, critical <14d
echo $?                                 # exit code: 0 OK / 1 warning / 2 critical
```

Domains are listed one per line in `scripts/domains.txt`. Blank lines and
lines starting with `#` are ignored, so the list can be annotated.

### Sample output

```
🟢 OK: github.com — 85 days remaining
🟡 WARNING: example.com — expires in 21 days
🔴 CRITICAL: expired.badssl.com — EXPIRED 4164 days ago
```

### Exit codes (Nagios convention)

| Code | Meaning |
|------|---------|
| 0 | All certificates OK |
| 1 | At least one certificate inside the warning window |
| 2 | At least one certificate critical, expired, or unreachable |

Machine-readable exit codes are what turn a script into infrastructure: a
scheduler or CI system doesn't read the text output — it reads the exit code
and decides whether to alert. This is the same 0/1/2 convention used by
Nagios-style monitoring systems.

---

## How it works — the TLS handshake

A website's certificate is public by design: it is the server's identity
document, and it must be shown to every connecting client *before* any
encryption begins — that's how the server proves it really is who it claims
to be. This script simply performs the opening of a normal HTTPS connection
and reads the document it is handed:

1. **TCP connect** — `openssl s_client` opens a connection to the host on
   port 443, exactly as a browser would.
2. **ClientHello + SNI** — the client announces it wants to speak TLS. The
   `-servername` flag sets **SNI (Server Name Indication)**: because many
   sites can share one IP address, SNI tells the server *which* site's
   certificate to present. Without it, you can receive the wrong certificate.
3. **The server presents its certificate** — in the clear, to anyone who asks.
   It contains only public metadata: the domain it was issued for, the
   issuing authority, the public key, and the validity window
   (`notBefore` / `notAfter`).
4. **Parse and leave** — a browser would continue the handshake into an
   encrypted session; this script instead pipes the certificate into
   `openssl x509 -noout -enddate`, extracts the `notAfter` date, converts it
   to epoch seconds, and computes days remaining with integer arithmetic.

The private key never leaves the server and is never involved here — the
certificate (public) and the private key (secret) are the two halves of TLS:
anyone can verify the server's identity; only the server can prove it.

Related fact: issued certificates are also recorded in public, append-only
**Certificate Transparency** logs (searchable at crt.sh), so this metadata is
not just visible to connecting clients — the ecosystem mandates its publicity
so fraudulent certificates can be detected.

---

## Design decisions

- **`set -euo pipefail`** — strict mode: exit on error (`-e`), treat unset
  variables as errors (`-u`), and fail a pipeline if *any* command in it
  fails, not just the last (`-o pipefail`).
- **Nagios exit codes (0/1/2)** — so the script can be consumed by cron, CI,
  or any monitoring system without parsing its text output.
- **SNI via `-servername`** — correctness on shared-IP hosting (see above).
- **GNU/BSD `date` portability** — Linux (`date -d`) and macOS
  (`date -j -f`) parse dates differently; the script tries GNU first and
  falls back to BSD, so it runs unmodified on both.
- **Config separated from code** — the domain list lives in `domains.txt`,
  not hardcoded in the script.
- **Fail loudly on unreachable hosts** — a certificate that can't be
  retrieved is treated as critical, not skipped: in monitoring, silence is
  the most dangerous failure mode.

---

## Scope — what this tool checks and what it doesn't

This tool validates **expiry only** — one of several independent dimensions a
browser checks on every certificate:

1. **Expiry** — is today inside the certificate's validity window? *(covered here)*
2. **Hostname match** — was the certificate issued for the domain being
   visited (SAN field)? A cert can be perfectly in-date but belong to the
   wrong host — e.g. `wrong.host.badssl.com` presents a valid `*.badssl.com`
   certificate that doesn't cover it, since wildcards match only one level.
3. **Chain of trust** — is it signed by a trusted certificate authority?
4. **Revocation** — has the issuer withdrawn it before expiry?

Dimensions 2–4 are deliberately out of scope for now; a monitoring tool
should be precise about what it does and doesn't claim to verify.

## Planned enhancements

- **Hostname verification:** `openssl s_client` supports
  `-verify_hostname <domain>`, and its output includes a `Verify return code`
  that can be parsed to flag valid-but-mismatched certificates (the
  `wrong.host.badssl.com` case) alongside expiry warnings.
- **Scheduled run via GitHub Actions:** weekly `schedule:` workflow that goes
  red on a non-zero exit code, turning the script into running automation.

---

## Real-world deployment

This repo stores the tool; in production the same script would be *scheduled*
so it runs without a human. Typical patterns, simplest first:

- **cron on a server** — e.g. `0 8 * * 1 /usr/local/bin/check-certs.sh`
  (every Monday 08:00), with output mailed or pushed to Slack on non-zero
  exit.
- **Scheduled CI job** — the script stays in this repo and a GitHub Actions
  workflow runs it on a `schedule:` trigger; a bad exit code turns the run
  red and notifies. No server needed.
- **Kubernetes CronJob** — the script in a small container image, scheduled
  by the cluster.
- **Managed monitoring** — platforms like Datadog offer certificate-expiry
  checks as a built-in synthetic test. This tool is the from-scratch version
  of that checkbox: the point of building it is owning every layer of what
  the checkbox does.


## inspect-mac.sh — process, inode & deleted-file inspection

A diagnostic tool with three modes: `process <pid>`, `inode <file>`, and
`deleted`. Written for macOS (Darwin/BSD), which exposes process and file
internals through tools (`ps`, `lsof`, `stat`) rather than a `/proc` filesystem.

### Linux equivalent — the `/proc` filesystem

On Linux, the same data lives in `/proc`, a *virtual* filesystem the kernel
generates in memory (nothing on disk). Each running process has a folder
`/proc/<pid>/` — the same source `ps` and `top` read:

- `/proc/<pid>/stat` / `status` — process state and memory (e.g. `VmRSS`,
  the resident RAM in use). macOS equivalent: `ps -o stat=,rss=`.
- `/proc/<pid>/cmdline` — the launch command (arguments NUL-separated).
- `/proc/<pid>/fd/` — one symlink per open file descriptor. macOS
  equivalent: `lsof -p <pid>`.

**Process states:** R running · S sleeping (healthy) · D/U uninterruptible I/O
wait (can't be killed — often signals disk/network trouble) · Z zombie
(exited, parent never reaped it) · T stopped.

### Inodes

An inode is the filesystem's metadata record for a file: inode number,
permissions, owner, size, timestamps, link count, and pointers to the data
blocks — **but not the filename**. The name lives in the directory, as a
`name -> inode number` mapping. Consequences: renaming is instant (only the
directory entry changes); hard links are multiple names sharing one inode;
and `df -i` can show inode exhaustion even with free disk space.

### The deleted-file trick

Deleting a file only removes its directory entry. If a process still has the
file open, its data blocks stay allocated until that descriptor closes — which
is why `df` can still show a disk full after deleting a large log. The
`deleted` mode finds these (`lsof | grep deleted` on macOS;
`/proc/*/fd` entries marked `(deleted)` on Linux). Fix: restart the process
holding it.