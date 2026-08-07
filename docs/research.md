# Skep research notes

Research date: 2026-08-06.

These notes capture the evidence behind the initial architecture. They are a
snapshot, not a substitute for pinning and testing the exact dependency
versions used by the implementation.

## Implementation decision after the spikes

The MVP is a native SwiftUI/AppKit application, not the Tauri/WebAssembly
architecture originally considered below. The terminal spike showed that
Ghostty's full native `GhosttyKit` can be built as a static XCFramework and
embedded as a real Metal-backed AppKit surface. That gives Skep Ghostty's
renderer, text model, input handling, selection, and PTY process ownership
without recreating those layers in a webview.

The resulting split is:

- SwiftUI for the host/template/workspace UI;
- a narrow Swift `SkepTerminal` adapter around a pinned `GhosttyKit`;
- OpenSSH or `gcloud compute ssh --tunnel-through-iap` subprocesses;
- a Rust protocol, bridge CLI, and Linux systemd daemon;
- Microsandbox v0.6.8 installed under a service-owned `MSB_HOME`.

The Rust code is not shared into the Mac process in the MVP. Protocol models
are mirrored in Swift and covered by live-shape integration tests. This costs
some duplicate types but removes the Tauri/webview/native-addon layers and
makes the terminal a first-class macOS view.

## Sources inspected

| Project | Revision inspected | License |
| --- | --- | --- |
| [Microsandbox](https://github.com/superradcompany/microsandbox) | `2208be04a59a4aedb80ae305e47c4ca4cb67b4a0` | Apache-2.0 |
| [Beehive](https://github.com/storozhenko98/beehive) | `2b765bea436b69799a777df0fae960728e3fdf15` | MIT |
| [Ghostty](https://github.com/ghostty-org/ghostty) | `f9b2ad8dbed93e0b8cdd6320d8f5a46ba15c5bc8` | MIT |
| [Runtime integration](https://github.com/superradcompany/microsandbox) | `2208be04a59a4aedb80ae305e47c4ca4cb67b4a0` | Apache-2.0 |

Google Cloud's nested-virtualization and IAP documentation was also checked on
the research date.

## Microsandbox findings

The inspected workspace reports version `0.6.8` and contains:

- a Rust SDK plus TypeScript, Python, and Go SDKs;
- the `msb` CLI;
- OCI image and named-volume management;
- local disk-only snapshots with create/list/inspect/verify/save/load/remove;
- start, stop, restart, live CPU/memory changes within boot ceilings, and
  metrics;
- IPv4 and IPv6 guest networking, DNS, network policy, and port forwards;
- a native SSH client and an SSH server/stdio `ProxyCommand` bridge;
- `microsandbox-agentd`, which is the init/agent process inside a guest.

Important boundary: the project describes itself as embeddable without a
long-running host daemon. A Skep daemon is therefore complementary rather than
a renamed Microsandbox service. It supplies remote policy, desired state,
reboot reconciliation, version management, and a stable protocol for the GUI.

Snapshots are local and disk-only at this revision. They capture a stopped
sandbox's writable upper layer and image identity. They do **not** capture a
running VM's memory or every launch-time setting. Skep therefore needs a
versioned template manifest adjacent to each snapshot.

Suggested template manifest fields:

```text
id, name, schema_version
microsandbox_version, snapshot_digest, base_image_digest
architecture
starting_cpus, maximum_cpus
starting_memory_mib, maximum_memory_mib
root_upper_mib, tmpfs_mounts
named_volume_specs
network_policy, dns_servers, port_forwards
shell, workdir, init/entrypoint
created_at, updated_at
```

Microsandbox has direct SSH support, but Skep can keep the desktop-to-host
boundary uniform by tunneling all operations through the host's SSH connection
and letting `skepd` use the local Rust SDK.

## Runtime integration setup findings

Early Skep runtime experiments established the desired core behavior:

- prepare a builder interactively;
- install Docker, agent tooling, credentials, and development dependencies;
- stop and snapshot the builder;
- create many isolated workers from the snapshot in seconds;
- preserve or destroy each worker independently.

The operational lessons that must become product behavior are:

1. **Runtime settings are not snapshot settings.** CPU/RAM, tmpfs, DNS,
   networking, ports, and volumes must be reapplied on every launch.
2. **Docker needs an ext4 disk-backed volume.** `overlay2` on the
   Microsandbox overlay root fails with `EINVAL`. Mount a named disk volume at
   `/var/lib/docker` for each workspace.
3. **The default `/tmp` can be too small.** Agent runtimes can fill a 128 MiB
   tmpfs. The proven setup uses 1 GiB.
4. **The default CPU allocation is too small for development.** Starting and
   maximum allocations should be explicit, visible, and adjustable.
5. **The guest normally does not run systemd.** PID 1 is agentd, so Docker and
   other services need a launch script or an explicitly selected init image.
6. **Host-resolver state is captured at boot.** This caused failures on a
   roaming laptop. Persistent Linux hosts are less volatile, but Skep should
   expose DNS choice and make resolver failures diagnosable.
7. **Ports do not collide across workspaces, but host access requires an
   explicit forward.** Port declarations belong in the launch profile.
8. **Native modules are architecture/OS specific.** macOS `node_modules`
   cannot be copied into a Linux guest.
9. **Volumes outlive sandbox deletion unless explicitly removed.** The destroy
   flow must enumerate and confirm them.
10. **Credentials in snapshots are credentials in export archives.** Publishing
    and export need a security warning and, later, a secret scanner.

The setup used fixed public resolvers because the host was a Mac that roamed
between networks. On a stable cloud Linux host, inheriting host DNS is a safer
general default; Skep should allow an opt-in pinned-resolver
behavior as an override.

## Beehive findings

Beehive is directly relevant as product and implementation prior art:

- Tauri 2 desktop app with React/TypeScript frontend and Rust backend;
- real PTYs through `portable-pty`;
- terminal panes rendered with xterm.js;
- persistent pane layouts and per-workspace terminal/agent sessions;
- Git and GitHub operations through local CLIs;
- agent attention events;
- signed and notarized Apple Silicon distribution.

The useful ideas to carry forward are the workspace/session hierarchy,
attention state, terminal lifecycle, local CLI integration, and release
pipeline. Skep should not carry over the hive/nest/comb vocabulary or the
filesystem-clone data model.

Because Beehive is MIT-licensed, code can be reused with its copyright and
license notice preserved. Reuse should be intentional and traceable rather
than copying the whole application as a starting point.

## Ghostty findings

Ghostty exposes two relevant embedding surfaces. `libghostty-vt` is the
portable terminal-state engine, while the native `GhosttyKit` XCFramework
contains the complete macOS surface used by Ghostty itself. The latter still
requires an embedding application to provide runtime callbacks, an `NSView`,
focus and geometry updates, and clipboard/security decisions, but it includes
the renderer and process/PTY integration that a `libghostty-vt` web renderer
would have had to rebuild.

The native spike proved:

- a static arm64 XCFramework builds with Zig 0.16;
- an AppKit view backed by `CAMetalLayer` can create and resize a Ghostty
  surface;
- the surface can execute the app's real OpenSSH command;
- rendered terminal text can be read back in a test to prove the remote marker
  reached the grid;
- keyboard, mouse, scrolling, focus, clipboard, title, cursor, and child-exit
  callbacks can be bridged through a small Swift adapter.

Ghostty's embedding API still changes, so the build script pins exact commit
`f9b2ad8dbed93e0b8cdd6320d8f5a46ba15c5bc8` and all Ghostty-specific code is
kept inside `SkepTerminal`.

## Google Compute Engine findings

Google Cloud supports KVM as the L1 hypervisor for nested virtualization. Its
current documentation says:

- enable `advancedMachineFeatures.enableNestedVirtualization` or use
  `gcloud compute instances create --enable-nested-virtualization`;
- a compatible Intel platform is required (the example sets a minimum of
  Intel Haswell);
- E2, memory-optimized, AMD, Arm, and H4D VM families are excluded;
- nested workloads can incur 10% or greater overhead, particularly for I/O;
- an existing VM can be updated, but the documented flow permits a disruptive
  restart.

Skep should inspect the instance metadata before SSH preflight so it can
explain a missing `/dev/kvm` as a cloud configuration issue rather than trying
to repair it inside the guest.

For IAP:

- `gcloud compute ssh --tunnel-through-iap` is the supported SSH path;
- `gcloud compute start-iap-tunnel ... --listen-on-stdin` can act as an
  OpenSSH proxy transport;
- `gcloud compute ssh ... --dry-run` emits the complete OpenSSH command;
- the VM does not need an external IP;
- IAM and a firewall rule permitting the IAP source range to TCP 22 are
  required.

The first implementation should shell out to the installed `gcloud` CLI so it
inherits the user's authentication, federated-login support, and SSH key/OS
Login behavior. Reimplementing IAP OAuth and SSH provisioning in Skep is not
justified for the MVP.

## Proposed host preflight

Preflight is read-only and returns structured evidence:

```text
connection: SSH handshake, host-key status, latency
identity: distro, version, kernel, architecture, user, sudo mode
virtualization: CPU vmx/svm flag, /dev/kvm, open/ioctl check, KVM modules
capacity: logical CPUs, total/available RAM, free disk, filesystem types
service: systemd availability and version
network: DNS, HTTPS, IPv4, IPv6, registry reachability
dependencies: curl, tar, zstd, iproute2, nftables/iptables
microsandbox: installed version, doctor result, data directory health
skepd: installed version, unit state, protocol compatibility
```

Checking that `/dev/kvm` exists is insufficient. The daemon installer should
perform an actual open/ioctl or `msb doctor` validation as the service user.

## Proposed protocol boundary

The app talks to a versioned Skep protocol, never raw `msb` output. This keeps
GUI behavior stable when the pinned Microsandbox version changes.

The initial transport can be length-delimited JSON control messages plus
typed binary stream frames over stdin/stdout:

```text
request(id, method, params)
response(id, result | error)
event(operation_id, kind, payload)
stream_open(stream_id, kind, metadata)
stream_data(stream_id, bytes)
stream_resize(stream_id, rows, cols)
stream_close(stream_id, status)
```

All destructive methods take immutable IDs and an expected generation. That
prevents a stale client or reused display name from deleting the wrong
workspace or volume.

## Remaining implementation questions

1. Should reconnecting to the same long-running shell or agent use a
   Skep-owned guest `tmux` session first, or move directly to a daemon-owned
   session broker?
2. After the first real KVM-host lifecycle run, which Microsandbox calls should
   move from the pinned CLI adapter to its Rust SDK?
3. Should concurrent IAP RPC and terminal channels use OpenSSH ControlMaster,
   or remain independent `gcloud compute ssh` processes?
4. Which compatible GCE machine families provide the best cost/performance for
   nested development microVMs in the target regions?
5. How should template secrets be detected, redacted, or injected without
   breaking zero-friction agent workflows?
