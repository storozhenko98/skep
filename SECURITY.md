# Security policy

Skep manages shell access and isolated development machines on infrastructure
controlled by its user. A vulnerability in its SSH command construction,
privilege boundary, update verification, daemon protocol, installer, or
destructive-operation guards may have a high impact.

## Supported versions

Security fixes are made on the default branch and released in the newest signed
macOS build. Older beta builds are not supported after a fixed update is
available.

## Reporting a vulnerability

Do not open a public issue. Use GitHub's private vulnerability-reporting form:

<https://github.com/storozhenko98/skep/security/advisories/new>

If that form is unavailable, email `storozhenkomykyta@gmail.com` with the
subject `Skep security report`. Include affected versions, reproduction steps,
impact, and any suggested mitigation. Remove real credentials, customer data,
and unrelated host contents from the report.

You should receive an acknowledgment within seven days. Disclosure timing will
be coordinated after the report is reproduced and a remediation is available.
This project does not currently operate a paid bug-bounty program.

## Security model

- Skep uses the user's existing OpenSSH or Google Cloud CLI credentials. It
  does not store SSH passwords or private keys.
- `skepd` listens on a local Unix socket, not a network port.
- Remote privileged operations are restricted to installed `skepctl` entry
  points and narrow sudo rules.
- Host and app payloads are checksum-verified. Production macOS updates also
  require Apple code signing, notarization, and a Sparkle Ed25519 signature.
- Shells intentionally execute with the authority of the selected local or
  remote account. Reports that only describe this documented behavior are not
  security vulnerabilities.
