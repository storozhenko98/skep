# Linux VM setup

## Supported MVP host

- Ubuntu 24.04 LTS;
- x86-64;
- systemd;
- SSH access from the Mac;
- glibc 2.39 or newer for the Microsandbox v0.6.8 release bundle;
- KVM accessible to the `skepd` service;
- outbound DNS and HTTPS;
- enough CPU, RAM, and disk for the host plus every concurrent microVM.

Microsandbox runs KVM microVMs. Docker inside those microVMs does not itself
need nested virtualization, but running KVM inside a cloud VM does. A cloud
host must therefore expose hardware virtualization to its guest and provide a
working `/dev/kvm`.

## Read-only preflight

Run these on the candidate host:

```sh
uname -m
. /etc/os-release && printf '%s %s\n' "$ID" "$VERSION_ID"
systemctl --version | head -1
grep -E -m1 '(^| )(vmx|svm)( |$)' /proc/cpuinfo
test -c /dev/kvm && ls -l /dev/kvm
```

The Mac app runs an equivalent raw SSH/IAP preflight before attempting any
`skepctl` RPC. A reachable fresh host is reported as **Setup required**, not as
a failed daemon connection. The app can install or repair the bundled Linux
host payload when the target is Ubuntu 24.04 x86-64 with systemd and the login
has non-interactive sudo.

After installing Microsandbox into the service-owned directory:

```sh
sudo MSB_HOME=/var/lib/skep/microsandbox \
  /var/lib/skep/microsandbox/bin/msb doctor
```

Skep's `host.info` performs the decisive check: it opens `/dev/kvm` and issues
the KVM API-version ioctl. The app disables builder creation and shows the
returned reason when that fails.

## Google Compute Engine

Use a Compute Engine machine family and CPU platform that support nested
virtualization, and enable nested virtualization when the instance is created.
This is a cloud-side property. Installing packages or loading kernel modules
inside an incompatible VM cannot make `/dev/kvm` appear.

For IAP connections, the Mac needs the Google Cloud CLI and an authenticated
account with the necessary IAP/Compute permissions. The instance needs an SSH
path permitted from IAP. Skep invokes:

```text
gcloud compute ssh INSTANCE --project PROJECT --zone ZONE \
  --tunnel-through-iap --command COMMAND
```

This lets `gcloud` retain responsibility for OAuth, OS Login/SSH keys, IAP,
and connection errors.

Official references:

- [Google Cloud nested virtualization](https://cloud.google.com/compute/docs/instances/nested-virtualization/overview)
- [Google Cloud SSH through IAP](https://cloud.google.com/iap/docs/using-tcp-forwarding)

## Generic SSH hosts

Skep delegates to `/usr/bin/ssh`, so normal SSH config, agents, identity files,
jump hosts, and host-key verification continue to apply. Configure key-based
authentication before adding the host; control RPC deliberately uses
`BatchMode=yes` and will not prompt for a password.

The daemon must be installed at `/usr/local/bin/skepd`, the bridge at
`/usr/local/bin/skepctl`, and the service-owned Microsandbox runtime at
`/var/lib/skep/microsandbox`. The installer creates a `skep` operator group and
narrow sudo rules for `skepctl bridge` and `skepctl workspace-shell`; it does
not grant general passwordless sudo. Set `SKEP_OPERATOR` during installation
when the intended SSH/IAP login is not `SUDO_USER`, then reconnect so its new
group membership applies. See the root README for commands.

The GUI installer uploads checksummed `skepd`, `skepctl`, service, and installer
files over the existing SSH/IAP connection. It installs the pinned
Microsandbox runtime first, then enables `skepd`, waits for
`/run/skep/skepd.sock`, and sends a protocol ping. GUI removal offers two
explicit paths. **Uninstall, keep data** stops and disables the service and
removes its binaries and sudo rule while preserving `/var/lib/skep`. **Erase
all data** first removes each managed microVM through Microsandbox, then deletes
`/var/lib/skep`, exports, templates, workspaces, volumes, Microsandbox, the Skep
helpers, systemd unit, sudo rule, runtime socket, and operator group. Neither
action deletes the underlying VM.

## Sizing

Skep treats these as independent controls:

- starting and maximum vCPUs;
- starting and maximum guest RAM;
- writable root-disk size;
- `/tmp` tmpfs size;
- Docker disk-volume size.

Increasing the root disk does not increase RAM or `/tmp`. The default
Microsandbox allocation is too small for many coding-agent workloads, so Skep
uses explicit values and clamps suggestions to the host. Always leave CPU and
RAM for Linux, `skepd`, and concurrent workspaces.

## Known incompatible-host result

The first supplied validation VM was Ubuntu 24.04 x86-64 and could run the
daemon, but exposed neither `vmx`/`svm` nor `/dev/kvm`. On that host Skep
correctly reports `kvm_unavailable` and refuses to create a builder. This is
the expected safe behavior; use a nested-virtualization-capable host for the
microVM lifecycle test.
