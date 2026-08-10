# Workspace navigation and terminal sessions

Status: first client-side navigation and in-app terminal-persistence phase implemented.

This note records the workspace-navigation and terminal-lifecycle direction
derived from the current Skep implementation and Beehive's workspace model.

## Product hierarchy

Skep's durable hierarchy should be:

```text
Host
└── Workspace
    └── Session
        └── Pane
```

- A **host** is This Mac, a regular SSH host, or a Google Cloud VM reached
  through IAP.
- A **workspace** is a persistent isolated microVM owned by one host.
- A **session** is an attachable interactive context inside a workspace.
- A **pane** is one visible terminal, agent, log, or future tool surface within
  a session.

Builders and templates remain host-management resources. They should not be
mixed into the runtime workspace switcher.

## Findings from Beehive

Beehive's useful behavior comes from treating workspaces as persistent
navigation destinations rather than opening terminals as disposable modals.
Its GUI keeps every opened comb and its terminal components mounted, then hides
the inactive combs. Switching combs therefore does not destroy their PTYs.

That persistence has a precise boundary:

- pane layouts are saved to disk;
- PTYs stay alive while their mounted components and the application process
  stay alive;
- unmounting a terminal closes its PTY;
- a configured `tmux new-session -A` startup command supplies stronger process
  persistence and reattachment.

Skep should carry forward the hierarchy, fast switching, pane lifecycle, and
future attention indicators. It should not copy the hive, nest, or comb
vocabulary.

## Sidebar direction

The existing host rail should become a lazy host-to-workspace tree rather than
gaining an unrelated global workspace tab.

```text
LOCAL
▾ This Mac
    ■ workspace                    RUNNING
    + New workspace

REMOTE HOSTS
▸ Skep test VM

▾ agent-host
    □ feature-auth                 STOPPED
    ■ pr-3085                      RUNNING
```

- Selecting a host opens the existing host-management surface: Overview,
  Builders, Templates, and Workspaces.
- Selecting a workspace opens a dedicated workspace mode in the main content
  area.
- The Workspaces management section remains the place to list, create, start,
  stop, and destroy machines. A sidebar workspace row is a direct entry into a
  particular machine.
- Workspace inventories should load only when a host is selected or expanded.
  Skep should cache already visited hosts instead of opening IAP/SSH connections
  to every configured host at launch.
- The status position on each workspace row should support running, stopped,
  disconnected, failed, and eventually agent-attention states.

## Workspace mode

A running workspace should open an embedded Ghostty terminal that fills the
main area. It should not use the current terminal sheet. The header should show
the parent host, workspace name, runtime state, and explicit lifecycle actions.

A stopped workspace should open a compact status surface with a Start action.
Selecting or leaving a workspace must never implicitly start, stop, or destroy
the microVM.

The first version should expose one terminal per workspace while keeping the
state model capable of multiple panes later. Likely future panes include shell,
agent, logs, and port-forward status.

## Persistence boundaries

Terminal persistence is not supplied by SSH itself. SSH and Google Cloud IAP
only transport terminal bytes between the Mac and the host.

Skep should distinguish four lifetimes:

1. **Workspace durability.** The microVM filesystem and Docker volume already
   survive terminal disconnects and app exits.
2. **Fast in-app switching.** Terminal controllers should be keyed by host,
   workspace, and pane. Open Ghostty views can remain mounted but hidden so
   switching workspaces does not reconnect.
3. **Client and transport reattachment.** `skepd` should eventually own the PTY
   session and let `skepctl` attach or detach. A dropped IAP/SSH connection or
   restarted Mac app could then reconnect to the same host-side session.
4. **Host-daemon restart recovery.** A guest-side multiplexer such as `tmux`, or
   a small Skep guest session helper, is required if the exact shell process
   must survive a host or daemon restart.

The current optional builder bootstrap installs `tmux`, but core terminal
persistence should not silently depend on an optional developer-tools action.
Either the guest session dependency must become part of the runtime contract,
or the product must clearly state the daemon-restart boundary.

## Recommended delivery sequence

1. Add lazy workspace children beneath host rows. **Implemented.** Inventories
   load when a host is selected, then remain cached for navigation.
2. Add a dedicated workspace mode with one embedded Ghostty terminal.
   **Implemented.** Stopped workspaces use a status/start surface.
3. Keep opened terminal views alive across workspace and host switching.
   **Implemented for the lifetime of the running Mac app.** Ghostty views remain
   mounted and are hidden when inactive.
4. Detect terminal-process exits and reconnect the client transport.
   **Implemented.** A dropped SSH/IAP process is shown as `CONNECTION LOST`
   without changing the workspace runtime state. The user can reconnect
   explicitly, and Skep makes a bounded set of attempts after macOS wakes or
   network connectivity returns. This opens a new guest shell; it does not yet
   recover the exact prior shell process.
5. Move attachable PTY ownership into `skepd` and add exact-session reattachment
   semantics to `skepctl`.
6. Add multiple panes, saved layouts, agent launch actions, and attention
   indicators.
7. Add guest-side session recovery only when persistence across host restarts is
   required.
