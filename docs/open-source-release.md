# Open-source release checklist

Repository visibility must remain private until every required item below is
complete. Licensing source code and publishing a repository are separate acts;
this repository can be prepared and licensed without changing its visibility.

## Ownership and provenance

- Confirm every committed file was authored for Skep or is included under a
  compatible license with its required notices.
- Confirm all contributors have the right to license their contributions under
  Apache-2.0.
- Keep acknowledgments for architectural prior art separate from licenses for
  code actually redistributed by Skep.
- Review the final diff and history for private infrastructure names, internal
  links, credentials, personal host data, and generated release binaries.

## Repository contents

- `LICENSE`, dependency notices, acknowledgments, contribution guidance,
  security policy, and support policy are present.
- `cargo fmt`, Clippy, Rust tests, Swift tests, and website validation pass.
- `RUST_THIRD_PARTY_LICENSES.html` is regenerated from the locked dependency
  graph and committed without a diff.
- The website source under `website/public` is unchanged unless a separate web
  copy review explicitly approves changes.
- Build output, signed archives, DMGs, app bundles, local credentials, and
  `.vercel` state are ignored and absent from reachable Git history.

## GitHub settings at launch

- Change visibility only as an explicit final action.
- Set the repository homepage to <https://skep-compute.vercel.app> and add
  focused topics such as `coding-agents`, `macos`, `microvm`, `rust`, and
  `swift`.
- Enable Issues and private vulnerability reporting.
- Enable secret scanning, push protection, dependency alerts, and automated
  security updates where GitHub makes them available.
- Require the CI workflow on the default branch and prevent force pushes after
  the cleaned history is published.
- Review the repository in a signed-out browser session so README links,
  images, downloads, issue forms, and security-reporting links work publicly.

## Release and announcement

- Keep signed application artifacts on the distribution site or a GitHub
  Release, not in the source history.
- Verify the DMG, contained app, Sparkle archive, appcast signature, checksums,
  notarization ticket, app icon, and anonymous download path.
- Publish a short architecture explanation, a concrete coding-agent workflow,
  the current beta limitations, and reproducible build instructions.
- Create the first public tag only after CI passes on the exact public commit.
