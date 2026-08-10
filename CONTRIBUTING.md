# Contributing to Skep

Thanks for helping improve Skep. This project spans a native macOS client, a
Rust host control plane, Linux installation scripts, and a static website.
Changes should preserve the trust boundary described in
[docs/architecture.md](docs/architecture.md): remote access stays inside the
user's existing SSH or Google Cloud transport, and `skepd` listens only on a
host-local Unix socket.

## Before opening a change

- Search existing issues before starting overlapping work.
- Keep pull requests focused and explain user-visible behavior and security
  implications.
- Never commit credentials, private keys, signing material, host inventories,
  cloud project identifiers, or generated release artifacts.
- Discuss protocol-breaking changes before implementing them. The Swift and
  Rust protocol models must remain compatible.

## Development setup

The supported client development environment is an Apple Silicon Mac running
macOS 14 or newer with Xcode 16 command-line tools, Swift 6, Zig 0.16 or newer,
and Rust. Linux hosts currently target Ubuntu 24.04 x86-64 with systemd and KVM.

Build the pinned Ghostty framework before testing the full Swift package:

```sh
./scripts/build-ghostty-framework.sh
```

Install `cargo-about` before regenerating the locked Rust dependency report:

```sh
cargo install --locked --version 0.9.1 --features cli cargo-about
```

Run the repository checks before submitting:

```sh
cargo fmt --all --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
cargo test --workspace
./scripts/generate-rust-licenses.sh
(cd apps/macos && swift test)
(cd website && npm run build && npm run check:source)
```

The committed Rust license report must remain in sync with `Cargo.lock`. The
website build output, application bundles, update archives, disk images, and
Ghostty XCFramework are generated locally and intentionally ignored by Git.
The full `npm run check` additionally validates signed release artifacts and is
used from a release checkout where those ignored files are present.

Swift dependencies are pinned in `apps/macos/Package.swift` and reviewed
manually together with Ghostty framework upgrades. GitHub's Swift dependency
updater cannot resolve this package until the ignored local Ghostty XCFramework
has been built, so Dependabot is limited to Cargo and GitHub Actions.

## Pull requests

Include:

1. the problem and intended behavior;
2. the implementation and important tradeoffs;
3. tests or a reason a change cannot be tested automatically;
4. screenshots for visible UI changes;
5. migration or compatibility notes for protocol, state, or packaging changes.

By submitting a contribution, you agree that it is your original work or that
you have the right to submit it, and that it is licensed under the Apache
License 2.0 in accordance with this repository's [LICENSE](LICENSE).

Please follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report security issues
privately according to [SECURITY.md](SECURITY.md).
