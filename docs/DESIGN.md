# Design

Status: decided in conversation, not implemented. Portable and compressed
sizes are unmeasured; the single-file form (below) is conditional on them. Anything stated here as a
fact about another repository was read from source in October 2026 and can be
re-checked there; this document records what was non-obvious, not what a
command can answer.

## Goal

The smallest self-contained way to get the latest Logos Basecamp release
**without relying on GitHub or other centralised services** for the bytes.
The artifact is a single file that can be shared by USB, on forums, etc.

## Decisions

- **What is decentralised.** The release bytes (served over Logos Storage) and
  "latest" (hardcoded in the file). The file itself remains one centralised
  hop: it has to come from somewhere.
- **Trust, best effort and documented.** Each artifact's CID and sha256 are
  hardcoded. The file is signed with a dedicated ed25519 key and verified
  with `ssh-keygen -Y verify`, because OpenSSH ships on Linux and macOS and
  `gpg` often does not (macOS). The key's fingerprint is published
  independently of the file and PGP-cross-signed by the owner, so the PGP
  chain is available to anyone who wants it. A signature inside the file
  proves nothing on its own: an attacker can replace the file and the key
  together. The fingerprint's independent publication is the trust anchor.
- **Platforms.** Whatever a Basecamp release supports; today Linux x86_64 and
  aarch64, and macOS arm64. macOS uses the notarized DMG.
- **Form.** One shell-headed file with an embedded storage fetcher per
  platform. This is conditional on measured size (see Risks); the fallback is a
  small folder or archive.
- **Fetcher.** Standalone: no package downloader, no `.lgx` catalog. The
  package downloader's catalog is for `.lgx` packages, requires `https`
  descriptors in v1, and is not needed once "latest" is hardcoded. Whether the
  fetcher is the official `logos-storage` CLI driven by shell or a custom binary
  on `libstorage.a` is decided on measured size: use the CLI if it is within
  about 20-30% of the custom binary.
- **Modes.** One file, subcommands:
  - `fetch` (default): download, verify, install minimally. Linux: the
    AppImage goes to `~/.local/bin`. macOS: mount the DMG with `hdiutil` and
    copy the app to `~/Applications`. No desktop entries, no PATH changes.
  - `serve`: keep seeding what was fetched, by re-uploading the same bytes.
    Must start the node with a very large `block-ttl` (see Risks).
  - `publish <file>`: lives in the release tooling that generates the file,
    not in the file users receive.
- **No seeders.** `fetch` exits with a clear message by default and asks the
  user whether to fall back to a hardcoded GitHub URL, verified against the
  hardcoded sha256. If they accept, it then offers to `serve`, so the first
  user becomes the seeder. This only works if the CID is reproducible, so the
  filename and block size are pinned.
- **Seeding.** Anyone who fetches may re-seed (BitTorrent-style). The first
  seeder is the upstream Basecamp team if they publish releases to Logos
  Storage; otherwise it is this project's release tooling, via `publish`.
- **Bootstrap.** The Logos fleet presets only (`logos.test` / `logos.dev`).
  A custom bootstrap flag is future work.
- **Ownership.** This repository and the signing key are the owner's. Basecamp
  need not adopt it. If Basecamp publishes releases to Logos Storage, use their
  CID instead; see the CID note below.

## Facts that shaped the design

- Basecamp ships AppImage (Linux x86_64, aarch64), a macOS app as an unsigned
  `.app.tar.gz` from GitHub Actions, a signed and notarized DMG from Jenkins,
  and a Windows NSIS installer (cross-built, not executed in that repo's CI).
  It has no self-update. Which macOS artifact is "official" is undocumented.
- `libstorage` is a shared or static library with a C API built from
  `logos-storage-nim` (`make STATIC=1 libstorage`; link also needs
  `libnatpmp`, `miniupnpc`, `libbacktrace`, `libplum`). There is no
  fetch-one-CID-and-exit call: every path starts a node, downloads, stops.
  Ephemeral fetches should pass `advertise=false`.
- `logos-storage-nim` GitHub releases publish no binary assets, so sizes can
  only come from a build.
- **A CID is not just a function of the bytes.** It is the manifest CID, and
  the manifest includes `filename`, `mimetype` and `blockSize`. Changing the
  filename or chunk size changes the CID. Publishing must pin both, and if
  upstream publishes with different settings, their CID is used as-is rather
  than re-uploading our own copy.
- **Content expires.** Blocks get `block-ttl` (default 30 days) and are
  deleted when it passes, including blocks that were downloaded rather than
  uploaded. The C API cannot extend expiry. Any `serve` or `publish` node must
  set a very large `block-ttl` at start, or hardcoded CIDs silently die.
- **Bootstrap is centrally operated.** The presets are raw public IPs
  generated from the Logos fleet. The same nodes act as AutoNAT servers and
  relay candidates, so NATed peers depend on them. Whether the fleet nodes
  run `--relay-server` is unconfirmed.
- No marketplace or paid persistence layer exists in the storage node;
  availability is "some node holds and advertises the content".

## Risks and open questions

Tracked as GitHub Issues; this is the summary.

- **Size.** Single-file viability depends on the size of the storage fetcher
  per platform. First measurement (dynamic Nix build, Linux x86_64, not
  portable, not compressed): `libstorage.so` 23.3 MB, `storage` CLI 29.2 MB,
  about 25% larger and so borderline against the 20-30% rule. The portable and
  compressed numbers decide it.
- **Fleet dependence.** Bootstrap, AutoNAT and relay all rely on the central
  fleet. Behaviour with the fleet unreachable is untested.
- **Seeder retention.** At least one node must stay up with a large
  `block-ttl`; nothing automatic keeps the content alive.
- **Key trust.** The signing key's trust anchor lives outside the file.
- **macOS.** Untested that a CLI-fetched DMG mounts and runs cleanly, and that
  Gatekeeper accepts it.
- **Coverage gaps.** Windows and macOS x86_64 are not covered.
- **Release process.** Generating, signing and publishing the file per
  Basecamp release is manual until tooled.
