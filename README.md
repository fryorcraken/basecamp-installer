# basecamp-installer

Get the latest [Logos Basecamp](https://github.com/logos-co/logos-basecamp)
release without GitHub: one self-contained file, shareable by USB stick or
forum post, that fetches Basecamp over [Logos Storage](https://logos.co).

> **Status: design only.** Nothing is built yet. The design, the decisions
> behind it and the known risks are in [`docs/DESIGN.md`](docs/DESIGN.md);
> [GitHub Issues](https://github.com/fryorcraken/basecamp-installer/issues)
> are the roadmap and the sole source of truth for scope.

## The idea

Basecamp releases today live on GitHub Releases and the README says to
download from there. This project replaces that single download with a
file you can hand to someone:

- one shell-headed file with an embedded Logos Storage fetcher per platform;
- the CID and sha256 of each release artifact are hardcoded in it;
- `fetch` (the default) joins the storage network, downloads the artifact,
  verifies it, and installs it minimally;
- `serve` keeps seeding what was fetched, so anyone who has the file can help
  the next person get it.

"Latest" is whatever was latest when the file was generated; a new release
means a new file.

## What it is not

- It is not a Basecamp updater. Basecamp has no self-update and this does not
  add one.
- It does not remove every central dependency. The file itself has to come
  from somewhere, and joining the network uses the Logos fleet's bootstrap
  nodes. [`docs/DESIGN.md`](docs/DESIGN.md) lists each remaining one.

## Platforms

Whatever a given Basecamp release supports and Logos Storage can run on:
today Linux (x86_64, aarch64) and macOS (arm64). Windows and mobile are out
of scope for now.

## Licence

Dual MIT / Apache-2.0, at your option. See [`LICENSE-MIT`](LICENSE-MIT) and
[`LICENSE-APACHE-v2`](LICENSE-APACHE-v2).

---

basecamp-installer is a personal, independent project. It is not built for, on
behalf of, or as part of the work of Logos or the Institute of Free Technology,
and has not been reviewed, audited, approved or endorsed by either.
