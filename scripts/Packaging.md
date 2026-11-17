# Packaging and installing Oktopus

| Script | Run by | Purpose |
| --- | --- | --- |
| `make-release.sh` | the maintainer, on the build host | builds a release tarball |
| `install-release.sh` | the recipient, from the unpacked tarball | loads the images and optionally starts/stops Oktopus |
| `ReleaseNotes.template.txt` | `make-release.sh` | template for the `ReleaseNotes.txt` shipped in the package |

## 1. Building a package

The package bundles, for **amd64 and arm64** (or just one with `--platforms`), every Oktopus image (any service in
`deploy/compose/docker-compose.yaml` with a `build:` block) and the third-party images the compose
file uses (`nats`, `mongo`, `nginx`; Portainer only with `--with-portainer`). The target machine
needs no Internet access and builds nothing. The compose file is the single source of truth for the
image list and build contexts.

Images are taken from a registry as `<registry>/oktopusp/<service>:<tag>`
(default `localhost:5000/oktopusp/<service>:latest`).

### Prerequisites

Docker with the Compose plugin and buildx, plus a registry the builder can push to, e.g.:

```bash
docker run -d -p 5000:5000 --name registry registry:2
docker buildx create --name system-builder --driver docker-container \
  --driver-opt network=host --use      # a local http registry may need a buildkitd config
export BUILDX_BUILDER=system-builder
```

Either build and push the images yourself, or let the script do it with `--build`.

### Build a release

```bash
scripts/make-release.sh v1.2 --build     # build+push both platforms, then package
scripts/make-release.sh v1.2             # package images already in the registry
```

`<version>` may be given with or without the leading `v`. The script:

1. (with `--build`) runs `docker buildx build --platform linux/amd64,linux/arm64 --push` per image;
2. pulls each image for each platform and saves them all into one tar per platform;
3. stages `releases/<version>_<date>/` and packs `releases/oktopus_<version>_<date>.tar.gz`.

Layout:

```
v1.2_20261116/
├── oktopus-images_amd64_v1.2_20261116.tar
├── oktopus-images_arm64_v1.2_20261116.tar
├── images.list                  # "<saved ref> <ref used by the compose file>"
├── docker-compose-release.yaml  # no build: blocks, Oktopus images pinned to :v1.2
├── .env.*   nats_config/   nginx.conf   firmwares/   images/
├── install-release.sh           # mode 700
└── ReleaseNotes.txt
```

### Options

| Option | Meaning | Default |
| --- | --- | --- |
| `<version>` | release version (required) | |
| `--registry HOST:PORT` | registry to pull from / push to | `localhost:5000` |
| `--prefix NAME` | repository prefix and image name prefix | `oktopusp` |
| `--tag TAG` | registry tag | `latest` |
| `--build` | build and push multi-platform images first | off |
| `--platforms LIST` | platforms to build and bundle: `amd64`, `arm64` or `amd64,arm64` | `amd64,arm64` |
| `--with-portainer` | also bundle Portainer | off |
| `--outdir DIR` | where to stage and write the release | `releases/` |
| `--force` | overwrite a release of the same version and date | off |
| `-h`, `--help` | usage | |

`releases/` is git-ignored. A failed build removes the incomplete release directory.

## 2. Installing a package

On the target (Docker + Compose plugin; amd64 or arm64):

```bash
tar -xzf oktopus_<version>_<date>.tar.gz
cd <version>_<date>
# edit .env.* and replace the default NATS credentials/certs as needed
./install-release.sh          # load the images for this CPU
./install-release.sh -r       # ... and start Oktopus
./install-release.sh -s       # stop and remove the containers (data kept)
```

`--profiles LIST` (or `COMPOSE_PROFILES`) selects the compose profiles; the default is
`nats,controller,cwmp,mqtt,stomp,ws,adapter,frontend`. Loading tags each image with the name in
`images.list` and removes the temporary registry tag unless it was already on the machine.

Published ports: frontend 3000, controller API 8000, nginx 80, file-server 8004, NATS 4222,
MQTT 1883/8883, WebSockets 8080, STOMP 61613, ACS 9292, socketio 5000, MongoDB 27017.
