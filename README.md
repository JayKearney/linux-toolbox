# linux-toolbox

Bash tools built to production habits. Current tool: an SSL/TLS certificate
checker with expiry + hostname verification, monitoring-grade exit codes, and a
scheduled GitHub Actions run. A process/inode inspector lives alongside it.

---

## check-certs.sh — SSL/TLS certificate checker

Checks every domain in `scripts/domains.txt`, reports days remaining before each
certificate expires (warning and critical thresholds), and verifies that the
certificate actually matches the hostname. Expired, unreachable, or mismatched
certificates are flagged.

Certificate problems are among the most common *entirely preventable* causes of
production outages: a cert quietly ages or gets misconfigured, nobody is
watching, and one morning every browser and API client refuses to connect. This
tool is the guardrail — run it on a schedule and the problem can never surprise
you.

### Usage

```bash
./scripts/check-certs.sh                # default thresholds: warn <30d, critical <7d
./scripts/check-certs.sh 45 14          # custom thresholds: warn <45d, critical <14d
echo $?                                 # exit code: 0 OK / 1 warning / 2 critical
```

Domains are listed one per line in `scripts/domains.txt`. Blank lines and lines
starting with `#` are ignored, so the list can be annotated.

### Sample output

```
🟢 OK: github.com — 84 days remaining
🟡 WARNING: revenue.ie — expires in 10 days
🔴 CRITICAL: expired.badssl.com — EXPIRED 4164 days ago
   ⚠️  expired.badssl.com — certificate does NOT match hostname
🟢 OK: wrong.host.badssl.com — 50 days remaining
   ⚠️  wrong.host.badssl.com — certificate does NOT match hostname
```

### Exit codes (Nagios convention)

| Code | Meaning |
|------|---------|
| 0 | All certificates OK |
| 1 | At least one certificate inside the warning window, or a hostname mismatch |
| 2 | At least one certificate critical, expired, or unreachable |

Machine-readable exit codes are what turn a script into infrastructure: a
scheduler or CI system doesn't read the text output — it reads the exit code and
decides whether to alert. This is the same 0/1/2 convention used by
Nagios-style monitoring systems.

---

## How it works — the TLS handshake

A website's certificate is public by design: it is the server's identity
document, and it must be shown to every connecting client *before* any
encryption begins — that's how the server proves it really is who it claims to
be. This script simply performs the opening of a normal HTTPS connection and
reads the document it is handed:

1. **TCP connect** — `openssl s_client` opens a connection to the host on port
   443, exactly as a browser would.
2. **ClientHello + SNI** — the client announces it wants to speak TLS. The
   `-servername` flag sets **SNI (Server Name Indication)**: because many sites
   can share one IP address, SNI tells the server *which* site's certificate to
   present. Without it, you can receive the wrong certificate.
3. **The server presents its certificate** — in the clear, to anyone who asks.
   It contains only public metadata: the domain it was issued for (and its
   Subject Alternative Names), the issuing authority, the public key, and the
   validity window (`notBefore` / `notAfter`).
4. **Parse and check** — the script extracts the `notAfter` date for the expiry
   check, and separately runs `-verify_hostname` for the hostname check.

The private key never leaves the server — the certificate (public) and the
private key (secret) are the two halves of TLS: anyone can verify the server's
identity; only the server can prove it. Issued certificates are also recorded in
public, append-only **Certificate Transparency** logs (searchable at crt.sh), so
this metadata is mandated to be public — which is how fraudulent certificates
get detected.

---

## What this tool checks

A browser validates a certificate on several independent dimensions. This tool
covers the first two:

1. **Expiry** — is today inside the certificate's validity window?
2. **Hostname match** — was the certificate issued for the host being visited
   (its SAN list)? Verified via `openssl -verify_hostname`, which returns
   `0 (ok)` on a match or `62 (hostname mismatch)` otherwise.
3. **Chain of trust** — signed by a trusted authority? *(out of scope)*
4. **Revocation** — withdrawn by the issuer before expiry? *(out of scope)*

### Why a certificate can be valid but not match the hostname

A mismatch means the cert is real and often in-date, but wasn't issued for the
host you connected to. Common real-world causes:

- **Wildcard scope (the `wrong.host.badssl.com` case)** — the server presents a
  valid `*.badssl.com` certificate, but wildcards match only **one** level, so
  it does not cover the deeper `wrong.host.badssl.com`. A very common
  misconfiguration.
- **Shared IP / wrong default certificate** — many sites share one server IP; a
  missing or wrong SNI default hands you another site's valid certificate.
- **Reused or misdeployed certificate** — a cert for one domain deployed onto a
  different host by mistake.
- **CDN / load-balancer gaps** — a new subdomain pointed at infrastructure whose
  certificate doesn't yet include it.
- **Connecting by raw IP** — the cert is issued for a domain name, not an IP, so
  it "mismatches."

In every case a browser still hard-blocks the connection, because a valid
certificate belonging to *someone else* is exactly what a man-in-the-middle
attack looks like. Expiry alone can't catch any of these — which is why hostname
verification is a separate check.

---

## Scheduled monitoring (GitHub Actions cron)

`.github/workflows/certs.yml` runs the checker automatically on a monthly cron
(`0 8 1 * *` — 08:00 UTC on the 1st) and can also be triggered manually via
`workflow_dispatch`. Because the script exits non-zero on any warning, critical,
expired, or hostname-mismatch result, a problem turns the workflow run red —
that red status (or an email alert) is the notification, no extra tooling
needed. Public domains stand in here for what would be your own services in
production, alerting the on-call channel.

---

## Design decisions

- **`set -euo pipefail`** — strict mode: exit on error (`-e`), treat unset
  variables as errors (`-u`), and fail a pipeline if *any* command in it fails,
  not just the last (`-o pipefail`).
- **Nagios exit codes (0/1/2)** — so the script can be consumed by cron, CI, or
  any monitoring system without parsing its text output.
- **SNI via `-servername`** — correct certificate on shared-IP hosting.
- **Hostname verification** — separate from expiry, because a cert can be
  in-date yet issued for the wrong host (see above).
- **Reads the last line without a trailing newline** (`while read || [[ -n
  "$domain" ]]`) — hand-edited files often omit it.
- **GNU/BSD `date` portability** — Linux (`date -d`) and macOS (`date -j -f`)
  parse dates differently; the script tries GNU first and falls back to BSD.
- **Config separated from code** — the domain list lives in `domains.txt`.
- **Fail loudly on unreachable hosts** — a certificate that can't be retrieved
  is treated as critical, not skipped: in monitoring, silence is the most
  dangerous failure mode.

---

## Real-world deployment

This repo stores the tool; in production the same script would be *scheduled* so
it runs without a human. Typical patterns, simplest first:

- **cron on a server** — e.g. `0 8 * * 1 /usr/local/bin/check-certs.sh`, with
  output mailed or pushed to Slack on non-zero exit.
- **Scheduled CI job** — the GitHub Actions workflow above.
- **Kubernetes CronJob** — the script in a small container image, scheduled by
  the cluster.
- **Managed monitoring** — platforms like Datadog offer certificate checks as a
  built-in synthetic test. This tool is the from-scratch version of that
  checkbox: the point of building it is owning every layer of what it does.

---

## inspect.sh / inspect-mac.sh — process, inode & deleted-file inspection

A diagnostic tool in two implementations: `inspect.sh` for Linux (reads the
`/proc` virtual filesystem) and `inspect-mac.sh` for macOS (uses `ps`, `lsof`,
`stat`). Three modes: `process <pid>`, `inode <file>`, and `deleted`. See the
comments in each script for the Linux ↔ macOS mapping, process states, the
inode/filename distinction, and the deleted-but-open-file trick.