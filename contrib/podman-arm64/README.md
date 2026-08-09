# contrib/podman-arm64 — run the Overleaf toolkit on podman + quadlets (ARM64)

This directory is a fork-local add-on for running Overleaf on an ARM64 VPS with
**podman** instead of docker, managed by **systemd quadlets** instead of
`docker compose`. It is intentionally self-contained: it only adds files,
never edits upstream ones, so re-basing on `overleaf/toolkit` upstream stays
trivial.

The toolkit itself is unchanged. Use `bin/init` as usual to create your
`config/` directory; this add-on takes over only the *runtime*.


## What lives here

```
contrib/podman-arm64/
├── README.md                     # you are here
├── Containerfile.fulltex         # overlay that adds the full TeX Live distribution
├── bin/
│   ├── build-sharelatex-image.sh # build sharelatex/sharelatex:<ver>-arm64 (and optional -fulltex) from source
│   ├── pull-deps.sh              # podman pull --platform=linux/arm64 for mongo + redis
│   ├── install-quadlets.sh       # render + install quadlets into ~/.config/containers/systemd/
│   └── status.sh                 # one-shot reporter (systemctl + podman ps)
└── quadlets/
    ├── sharelatex-data.volume    # bind-mount of OVERLEAF_DATA_PATH
    ├── mongo-data.volume         # bind-mount of MONGO_DATA_PATH
    ├── redis-data.volume         # bind-mount of REDIS_DATA_PATH
    ├── sharelatex.container
    ├── mongo.container
    └── redis.container
```


## Prerequisites

- An ARM64 (aarch64) Linux host — these scripts assume `uname -m` is `aarch64`.
- `podman` ≥ 4.4 with quadlet support (Fedora 39+, RHEL 9.2+, Ubuntu 24.04+,
  Debian 13+ — or any distro with a recent `podman` package).
- A systemd **user** session with lingering enabled so the services survive
  logout:

  ```sh
  sudo loginctl enable-linger "$USER"
  ```

- `git`, `openssl`, `curl`, and ~20 GB of free disk for the Overleaf build
  (TeX Live images are large).
- `shellcheck` if you plan to edit the scripts.


## Staying in sync with upstream

The toolkit upstream never edits files under `contrib/`, so the merge is
mechanical:

```sh
git remote add upstream https://github.com/overleaf/toolkit.git   # once
git fetch upstream
git rebase upstream/master          # or: git merge upstream/master
```

Your fork diff is entirely this `contrib/podman-arm64/` tree plus whatever
you put in `config/` (which is `.gitignore`d in the upstream repo anyway).


## One-time setup

```sh
# 1. generate toolkit config (toolkit command, untouched)
bin/init

# 2. edit config/overleaf.rc as usual — set OVERLEAF_LISTEN_IP,
#    OVERLEAF_DATA_PATH, MONGO_DATA_PATH, REDIS_DATA_PATH, etc.

# 3. build the Overleaf image natively for ARM64 (from the main branch)
contrib/podman-arm64/bin/build-sharelatex-image.sh

#    On a VPS with limited RAM (≤4 GB), use --low-memory:
#    contrib/podman-arm64/bin/build-sharelatex-image.sh --low-memory

#    To build a specific git ref instead of main:
#    contrib/podman-arm64/bin/build-sharelatex-image.sh --ref=<branch|tag|commit>

#    Want the full TeX Live distribution (every package, ~7 GB)?
#    Append --full-texlive. See "Full TeX Live overlay" below.
#    contrib/podman-arm64/bin/build-sharelatex-image.sh --full-texlive

# 4. pull mongo + redis (ARM64 images exist upstream)
contrib/podman-arm64/bin/pull-deps.sh

# 5. render and install the quadlets
contrib/podman-arm64/bin/install-quadlets.sh
#    The quadlet auto-detects the -fulltex image if you built it.
#    Override with OVERLEAF_FULL_TEXLIVE=true|false in config/overleaf.rc.
```


## Daily use

```sh
# start everything
systemctl --user start overleaf-sharelatex.service    # brings mongo + redis via Requires=
# or individually
systemctl --user start overleaf-mongo.service
systemctl --user start overleaf-redis.service
systemctl --user start overleaf-sharelatex.service

# follow logs
journalctl --user -u overleaf-sharelatex -f
journalctl --user -u overleaf-mongo -f

# status snapshot
contrib/podman-arm64/bin/status.sh

# stop / restart
systemctl --user stop overleaf-sharelatex.service
systemctl --user restart overleaf-sharelatex.service
```

Enable autostart on boot (the user quadlet units will start when the user
session starts, provided lingering is on):

```sh
systemctl --user enable overleaf-sharelatex.service overleaf-mongo.service overleaf-redis.service
```


## Upgrading Overleaf

```sh
# 1. let the toolkit bump config/version and variables.env
bin/upgrade

# 2. rebuild the ARM64 image at the new tag
contrib/podman-arm64/bin/build-sharelatex-image.sh
#    add --full-texlive if you used it before (and --low-memory on VPS)

# 3. restart
systemctl --user restart overleaf-sharelatex.service
```

`install-quadlets.sh` only needs to be re-run if you changed rc variables
(`OVERLEAF_LISTEN_IP`, `OVERLEAF_DATA_PATH`, `MONGO_DATA_PATH`, …). Most
upgrades don't need it.


## Full TeX Live overlay

The base Overleaf image ships with a curated subset of TeX Live — most
papers compile fine, but obscure packages will fail with "File not found".
If you need *every* package (~7 GB), build the fulltex overlay on top of
the ARM64 image:

```sh
contrib/podman-arm64/bin/build-sharelatex-image.sh --full-texlive
```

This produces a second image tagged `sharelatex/sharelatex:<ver>-arm64-fulltex`
and `install-quadlets.sh` will auto-detect it on the next install. To force
the choice:

```sh
# in config/overleaf.rc
OVERLEAF_FULL_TEXLIVE=true   # require -fulltex image; error if absent
OVERLEAF_FULL_TEXLIVE=false  # always use base image, even if -fulltex exists
# unset                      # auto-detect (default)
```

### Build flags

| Flag / env           | Meaning                                                                 |
| -------------------- | ----------------------------------------------------------------------- |
| `--full-texlive`     | Build the `-fulltex` overlay image after the base image.                |
| `--mirror-url=URL`   | TeX Live mirror URL. Passed as `TEXLIVE_MIRROR` to the base build and `TEXLIVE_MIRROR_URL` to the fulltex overlay. Use a closer mirror to speed up the download. |
| `--low-memory`       | Caps each build container at 4 GB RAM (`--memory=4g`) and sets `NODE_OPTIONS=--max-old-space-size=2048`. Use on VPS instances with ≤4 GB RAM. |
| `--ref=<ref>`        | Git ref to build from. Default: `main`. Use a specific commit hash, branch name, or tag for reproducible builds. |

The overlay installs the **current year's** TeX Live into
`/usr/local/texlive/<current-year>` and does not symlink or alias it.
The base image is expected to pick up whichever year the build happened
to run in.

### Example

```sh
# Build both images with the full texlive, a closer CTAN mirror, and
# resource limits suitable for a VPS with limited RAM:
contrib/podman-arm64/bin/build-sharelatex-image.sh \
    --full-texlive \
    --low-memory \
    --mirror-url=https://mirror.clientvps.com/CTAN/systems/texlive/tlnet/install-tl-unx.tar.gz

# Re-render the quadlets to pick the new -fulltex tag:
contrib/podman-arm64/bin/install-quadlets.sh
systemctl --user restart overleaf-sharelatex.service
```


## How the quadlets are wired

- Container names match the toolkit defaults (`sharelatex`, `mongo`, `redis`)
  so the rc defaults (`MONGO_URL=mongodb://mongo/sharelatex`,
  `REDIS_HOST=redis`) work without edits.
- All three containers live on a private podman bridge network named `overleaf`
  (created by `install-quadlets.sh` via `podman network create`) and resolve each
  other by container name via podman's built-in DNS (aardvark-dns).
- The `sharelatex` service has `Requires=` / `After=` on the mongo and redis
  services, so starting `overleaf-sharelatex.service` pulls them in automatically
  and waits for them to start before the sharelatex container is launched.
- Mongo carries a healthcheck (`mongosh` / `mongo`) equivalent to the one in
  `lib/docker-compose.mongo.yml`.
  - image ≥5: `OVERLEAF_MONGO_URL`, `OVERLEAF_REDIS_HOST`
  - image <5: `SHARELATEX_MONGO_URL`, `SHARELATEX_REDIS_HOST`
- `EnvironmentFile=` points at `config/variables.env` so mail/LDAP/SAML
  credentials are picked up the same way `docker compose --env-file` would
  load them.


## Troubleshooting

- **`sharelatex` can't resolve `mongo` / `redis`** — user quadlets only get
  DNS when the user session is "online". Run
  `sudo loginctl enable-linger "$USER"` and re-login.
- **`exec /usr/local/bin/...: operation not permitted`** — SELinux. With
  SELinux enforcing you may need `:z` on bind mounts; edit the rendered
  quadlet under `~/.config/containers/systemd/` and add `,relabel=shared` to
  the volume options, or set `Volume=...:z` instead of `:rw`.
- **Wrong image arch** — `podman image inspect sharelatex/sharelatex:6.2.2-arm64`
  should report `Architecture: arm64`. If it doesn't, re-run
  `build-sharelatex-image.sh`.
- **Mongo replica set not initiated** — the toolkit's `bin/up` does this on
  first run. With quadlets you do it manually:

  ```sh
  podman exec -it mongo mongosh \
    --eval 'db.isMaster().primary || rs.initiate({ _id: "overleaf", members: [ { _id: 0, host: "mongo:27017" } ] })'
  ```

- **Bind-mount path missing** — `install-quadlets.sh` does `mkdir -p` for the
  data directories, but only the ones configured. If you point
  `OVERLEAF_DATA_PATH` somewhere unusual, create it yourself first.


## Files reference

| File                                  | Purpose                                                                |
| ------------------------------------- | ---------------------------------------------------------------------- |
| `bin/build-sharelatex-image.sh`       | Build `sharelatex/sharelatex:<ver>-arm64` from `github.com/overleaf/overleaf`; optionally also build the `-fulltex` overlay. |
| `bin/pull-deps.sh`                    | Pull mongo + redis with `--platform=linux/arm64`.                      |
| `bin/install-quadlets.sh`             | Render templates + drop quadlets in the systemd user dir; creates the `overleaf` podman network; auto-detects the fulltex image. |
| `bin/status.sh`                       | Show service + container state.                                        |
| `Containerfile.fulltex`               | Overlay that installs the full TeX Live distribution on top of the base ARM64 image. |
| `quadlets/*-data.volume`              | Bind-mount volumes for persistent data.                                |
| `quadlets/mongo.container`            | Mongo 6+ with replica-set args + healthcheck.                          |
| `quadlets/redis.container`            | Redis with `--appendonly yes` when `REDIS_AOF_PERSISTENCE=true`.       |
| `quadlets/sharelatex.container`       | The Overleaf web service; pulls in mongo + redis via systemd Requires=/After=.


## Limitations vs. the toolkit's docker-compose path

This add-on is deliberately minimal:

- **No nginx** — terminate TLS at the host (caddy, haproxy, or a host
  nginx). Run `bin/init --tls` first if you want sample certs.
- **No git-bridge** — Server Pro's git-sync service. Add it later by
  following the same patterns here (new `.container` + `.volume`).
- **No sibling-containers** — Server Pro's sandboxed-compile path; it needs
  access to a container runtime socket, which is awkward under rootless
  podman and out of scope for a first cut.
- **No `bin/upgrade` automation** — the toolkit's `bin/upgrade` mutates
  `config/version` and `variables.env` (still useful), but the image build
  is a separate manual step.

Each of these can be added by following the patterns in `quadlets/`; the
existing toolkit compose fragments under `lib/docker-compose.*.yml` are a
good reference for the per-service config knobs.