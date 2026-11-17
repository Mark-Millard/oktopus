#!/usr/bin/env bash
#
# install-release.sh -- install the Oktopus Docker images from an unpacked release
# package (and, optionally, start the containers).
#
# This script ships inside the release tarball (scripts/make-release.sh copies it
# into the release directory). After `tar -xzf` just run it from there:
#
#   ./install-release.sh          # load the images for this machine's CPU
#   ./install-release.sh -r       # ... and start Oktopus
#   ./install-release.sh -s       # stop (and remove) the containers
#
# What it does:
#   1. Picks the image tar that matches this machine (x86_64 -> amd64,
#      aarch64/arm64 -> arm64).
#   2. `docker load`s it, tags every image with the name the bundled compose file
#      expects (see images.list), then removes the temporary registry tags the
#      images were saved under -- unless that tag already existed on this machine
#      before the load, in which case it is left alone.
#   3. With -r: `docker compose up -d` using docker-compose-release.yaml.
#
# Options:
#   -r, --run            Also start the containers (detached)
#   -s, --stop           Stop and remove the containers (no image is loaded). Data in
#                        ./mongo_data, ./nats_data etc. is kept.
#   --profiles LIST      Comma-separated compose profiles to start/stop (default:
#                        nats,controller,cwmp,mqtt,stomp,ws,adapter,frontend; or the
#                        COMPOSE_PROFILES environment variable if set).
#                        Available: nats controller cwmp mqtt stomp ws adapter frontend
#                        (and portainer, if the package was built --with-portainer)
#   -h, --help           Show this help
#
# Requires: docker (and the docker compose plugin for -r and -s).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
COMPOSE_REL="docker-compose-release.yaml"
COMPOSE_FILE="$SCRIPT_DIR/$COMPOSE_REL"
LIST_FILE="$SCRIPT_DIR/images.list"
DEFAULT_PROFILES="nats,controller,cwmp,mqtt,stomp,ws,adapter,frontend"

usage() {
  awk 'NR>1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print } else exit }' "${BASH_SOURCE[0]}"
}

die() { echo "error: $*" >&2; exit 1; }

RUN=0
STOP=0
PROFILES="${COMPOSE_PROFILES:-$DEFAULT_PROFILES}"
while [ $# -gt 0 ]; do
  case "$1" in
    -r|--run) RUN=1; shift ;;
    -s|--stop) STOP=1; shift ;;
    --profiles) PROFILES="${2:?--profiles needs a value}"; shift 2 ;;
    -h|-help|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ "$RUN" -eq 0 ] || [ "$STOP" -eq 0 ] || { echo "error: -r/--run and -s/--stop cannot be combined" >&2; exit 2; }

# --- prerequisites -----------------------------------------------------------

command -v docker >/dev/null 2>&1 || die "'docker' is required but was not found on PATH"
if ! docker info >/dev/null 2>&1; then
  die "cannot talk to the Docker daemon. Is it running, and is your user in the 'docker' group?
       (try: sudo usermod -aG docker \"\$USER\", then log out and back in)"
fi
if [ "$RUN" -eq 1 ] || [ "$STOP" -eq 1 ]; then
  docker compose version >/dev/null 2>&1 || die "the 'docker compose' plugin is required for -r and -s"
fi
[ -f "$COMPOSE_FILE" ] || die "$COMPOSE_REL not found next to this script ($SCRIPT_DIR)"

COMPOSE=(env "COMPOSE_PROFILES=$PROFILES" docker compose -f "./$COMPOSE_REL")
COMPOSE_HINT="COMPOSE_PROFILES=$PROFILES docker compose -f ./$COMPOSE_REL"

# --- stop only ------------------------------------------------------------------

if [ "$STOP" -eq 1 ]; then
  echo "==> stopping the containers (profiles: $PROFILES)"
  cd -- "$SCRIPT_DIR"
  "${COMPOSE[@]}" down --remove-orphans
  exit 0
fi

# --- pick the image tar for this machine --------------------------------------

[ -f "$LIST_FILE" ] || die "images.list not found next to this script ($SCRIPT_DIR)"

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported CPU architecture '$(uname -m)' (this package has amd64 and arm64 images)" ;;
esac

shopt -s nullglob
TARS=("$SCRIPT_DIR"/oktopus-images_"${ARCH}"_*.tar)
shopt -u nullglob
[ "${#TARS[@]}" -ge 1 ] || die "no oktopus-images_${ARCH}_*.tar found in $SCRIPT_DIR"
[ "${#TARS[@]}" -eq 1 ] || die "more than one ${ARCH} image tar found in $SCRIPT_DIR; expected exactly one"
IMAGE_TAR="${TARS[0]}"

# --- load and tag ---------------------------------------------------------------

# Which saved tags are already on this machine (never remove those afterwards).
PREEXISTING=" "
while read -r src dst; do
  [ -n "${src:-}" ] || continue
  if docker image inspect "$src" >/dev/null 2>&1; then PREEXISTING="$PREEXISTING$src "; fi
done < "$LIST_FILE"

echo "==> loading $(basename -- "$IMAGE_TAR") ($ARCH); this can take a few minutes"
docker load -i "$IMAGE_TAR" >/dev/null

while read -r src dst; do
  [ -n "${src:-}" ] || continue
  docker image inspect "$src" >/dev/null 2>&1 || die "image $src was not found after loading $IMAGE_TAR"
  if [ "$src" != "$dst" ]; then
    echo "==> tagging $src as $dst"
    docker tag "$src" "$dst"
    case "$PREEXISTING" in
      *" $src "*) echo "    leaving tag $src in place (it was already on this machine)" ;;
      *) docker rmi "$src" >/dev/null ;;
    esac
  fi
done < "$LIST_FILE"

echo "==> installed Docker images:"
awk '{print $2}' "$LIST_FILE" | sort -u | sed 's/^/    /'

# --- optionally run -----------------------------------------------------------------

if [ "$RUN" -eq 0 ]; then
  echo
  echo "To start Oktopus (from this directory):"
  echo "  ./install-release.sh -r"
  echo "or:"
  echo "  $COMPOSE_HINT up -d --remove-orphans"
  echo "To stop it later:"
  echo "  ./install-release.sh -s"
  exit 0
fi

echo "==> starting the containers (profiles: $PROFILES)"
cd -- "$SCRIPT_DIR"
"${COMPOSE[@]}" up -d --remove-orphans
echo
"${COMPOSE[@]}" ps
echo
echo "Oktopus is starting. Published ports (see $COMPOSE_REL):"
echo "  frontend :3000   controller API :8000   nginx :80   file-server :8004"
echo "  logs: $COMPOSE_HINT logs -f"
echo "  stop: ./install-release.sh -s"
