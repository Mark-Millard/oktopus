#!/usr/bin/env bash
#
# scripts/make-release.sh -- build a distributable Oktopus release tarball
# (releases/oktopus_<version>_<date>.tar.gz).
#
# The release bundles every Oktopus image (controller, MTPs, adapters, socketio,
# frontend, acs, file-server) plus the third-party images the compose file needs
# (nats, mongo, nginx), for amd64 and arm64, together with a ready-to-run compose
# file, the .env.* files, NATS config/certs, nginx.conf and install-release.sh, so
# the target machine needs no Internet access and no build.
#
# The image list and build contexts are read from deploy/compose/docker-compose.yaml
# (every service with a `build:` block is an Oktopus image), so that file stays the
# single source of truth.
#
# Images come from a registry (default: a local one), one tag per image
# <registry>/<prefix>/<service>:<tag>. Either build and push them first (see
# scripts/Packaging.md) or pass --build to have this script do it with buildx.
#
# Usage:
#   scripts/make-release.sh <version> [options]
#
#   <version>              e.g. "1.2" or "v1.2" (a leading "v" is added if missing).
#                          The images are tagged oktopusp/<service>:<version> on
#                          the target machine.
#
# Options:
#   --registry HOST:PORT   Registry to pull from / push to (default: localhost:5000)
#   --prefix NAME          Repository prefix in the registry and the image name
#                          prefix in the release (default: oktopusp)
#   --tag TAG              Registry tag to pull/push (default: latest)
#   --build                Build and push the multi-platform (amd64+arm64) images to
#                          the registry first, with docker buildx. Needs a buildx
#                          builder that can push to the registry (BUILDX_BUILDER).
#   --platforms LIST       Comma-separated platforms to build and bundle: amd64,
#                          arm64, or both (default: amd64,arm64)
#   --with-portainer       Also bundle the Portainer image and keep it usable
#   --outdir DIR           Where to stage/write the release (default: releases,
#                          relative to the repo root)
#   --force                Overwrite an existing release for the same version/date
#   -h, --help             Show this help
#
# Requires: docker (buildx for --build), tar, awk, sed, date.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"
DEPLOY_DIR="$REPO_ROOT/deploy/compose"

REGISTRY="localhost:5000"
PREFIX="oktopusp"
IMAGE_TAG="latest"
BUILD=0
WITH_PORTAINER=0
OUTDIR="$REPO_ROOT/releases"
FORCE=0
VERSION_ARG=""
PLATFORMS=(amd64 arm64)

usage() {
  awk 'NR>1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print } else exit }' "${BASH_SOURCE[0]}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --registry) REGISTRY="${2:?--registry needs a value}"; shift 2 ;;
    --prefix) PREFIX="${2:?--prefix needs a value}"; shift 2 ;;
    --tag) IMAGE_TAG="${2:?--tag needs a value}"; shift 2 ;;
    --build) BUILD=1; shift ;;
    --platforms) IFS=, read -r -a PLATFORMS <<< "${2:?--platforms needs a value}"; shift 2 ;;
    --with-portainer) WITH_PORTAINER=1; shift ;;
    --outdir) OUTDIR="${2:?--outdir needs a value}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      [ -z "$VERSION_ARG" ] || { echo "error: unexpected extra argument: $1" >&2; exit 2; }
      VERSION_ARG="$1"; shift ;;
  esac
done

[ -n "$VERSION_ARG" ] || { echo "error: missing <version> argument" >&2; usage >&2; exit 2; }
if ! [[ "$VERSION_ARG" =~ ^v?[A-Za-z0-9][A-Za-z0-9.+_-]*$ ]]; then
  echo "error: version '$VERSION_ARG' has characters that aren't safe in a file name" >&2
  exit 2
fi
VERSION="v${VERSION_ARG#v}"

for p in "${PLATFORMS[@]}"; do
  case "$p" in amd64|arm64) : ;; *) echo "error: unsupported platform '$p' (use amd64 and/or arm64)" >&2; exit 2 ;; esac
done
[ "${#PLATFORMS[@]}" -ge 1 ] || { echo "error: --platforms needs at least one platform" >&2; exit 2; }
BUILDX_PLATFORMS="$(printf 'linux/%s,' "${PLATFORMS[@]}")"; BUILDX_PLATFORMS="${BUILDX_PLATFORMS%,}"

case "$OUTDIR" in /*) : ;; *) OUTDIR="$REPO_ROOT/$OUTDIR" ;; esac

for cmd in docker tar awk sed date; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "error: '$cmd' is required but not found on PATH" >&2; exit 1; }
done

DATE="$(date +%Y%m%d)"
NAME="${VERSION}_${DATE}"
RELDIR="$OUTDIR/$NAME"
TARBALL="$OUTDIR/oktopus_${NAME}.tar.gz"

COMPOSE_SRC="$DEPLOY_DIR/docker-compose.yaml"
INSTALL_SRC="$SCRIPT_DIR/install-release.sh"
NOTES_TEMPLATE="$SCRIPT_DIR/ReleaseNotes.template.txt"
for f in "$COMPOSE_SRC" "$INSTALL_SRC" "$NOTES_TEMPLATE" "$DEPLOY_DIR/nginx.conf" "$DEPLOY_DIR/nats_config/nats.cfg"; do
  [ -f "$f" ] || { echo "error: expected source file not found: $f" >&2; exit 1; }
done

if [ -e "$RELDIR" ] || [ -e "$TARBALL" ]; then
  if [ "$FORCE" -ne 1 ]; then
    echo "error: $RELDIR or $TARBALL already exists" >&2
    echo "       pass --force to overwrite, or run again after the date changes" >&2
    exit 1
  fi
  rm -rf -- "$RELDIR" "$TARBALL"
fi

# --- read the image list from the compose file --------------------------------
# Output lines: service|image|context   (context empty for third-party images)
SERVICES="$(awk '
  function flush() { if (svc != "" && img != "") print svc "|" img "|" ctx; svc=""; img=""; ctx="" }
  /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { flush(); svc=$1; sub(/:$/, "", svc); next }
  /^    image:/   { img=$2; gsub(/"/, "", img); next }
  /^      context:/ { ctx=$2; next }
  /^[^ #]/ { flush() }
  END { flush() }
' "$COMPOSE_SRC")"
[ -n "$SERVICES" ] || { echo "error: no services found in $COMPOSE_SRC" >&2; exit 1; }

OWN_SVCS=()   # service|image|context for Oktopus images (have a build: context)
EXT_IMAGES=() # third-party image refs to bundle
while IFS='|' read -r svc img ctx; do
  if [ -n "$ctx" ]; then
    OWN_SVCS+=("$svc|$img|$ctx")
  else
    if [ "$svc" = "portainer" ] && [ "$WITH_PORTAINER" -ne 1 ]; then continue; fi
    EXT_IMAGES+=("$img")
  fi
done <<< "$SERVICES"

cleanup_on_failure() {
  echo "==> release build failed; removing incomplete $RELDIR" >&2
  rm -rf -- "$RELDIR" "$TARBALL"
}
trap cleanup_on_failure ERR

# --- optionally build and push the multi-platform images ------------------------
if [ "$BUILD" -eq 1 ]; then
  docker buildx version >/dev/null 2>&1 || { echo "error: --build needs docker buildx" >&2; exit 1; }
  for entry in "${OWN_SVCS[@]}"; do
    IFS='|' read -r svc img ctx <<< "$entry"
    ctxdir="$(cd -- "$DEPLOY_DIR/$ctx" && pwd)"
    dst="${REGISTRY}/${PREFIX}/${img##*/}:${IMAGE_TAG}"
    echo "==> building and pushing $dst ($BUILDX_PLATFORMS)"
    docker buildx build --platform "$BUILDX_PLATFORMS" --push \
      -t "$dst" -f "$ctxdir/build/Dockerfile" "$ctxdir"
  done
fi

echo "==> staging release in $RELDIR"
mkdir -p "$RELDIR"

# images.list: "<ref as saved in the tar> <ref the release compose file uses>"
: > "$RELDIR/images.list"
OWN_SRC_REFS=()
for entry in "${OWN_SVCS[@]}"; do
  IFS='|' read -r svc img ctx <<< "$entry"
  src="${REGISTRY}/${PREFIX}/${img##*/}:${IMAGE_TAG}"
  OWN_SRC_REFS+=("$src")
  echo "$src ${PREFIX}/${img##*/}:${VERSION}" >> "$RELDIR/images.list"
done
for img in "${EXT_IMAGES[@]}"; do
  echo "$img $img" >> "$RELDIR/images.list"
done

for arch in "${PLATFORMS[@]}"; do
  refs=("${OWN_SRC_REFS[@]}" "${EXT_IMAGES[@]}")
  echo "==> pulling ${#refs[@]} images for linux/$arch"
  for ref in "${refs[@]}"; do
    docker pull -q --platform "linux/$arch" "$ref" >/dev/null
  done
  echo "==> saving linux/$arch images"
  docker save --platform "linux/$arch" -o "$RELDIR/oktopus-images_${arch}_${NAME}.tar" "${refs[@]}"
done

# --- deployment files ----------------------------------------------------------------
echo "==> copying deployment files"
cp -R "$DEPLOY_DIR/nats_config" "$RELDIR/nats_config"
cp "$DEPLOY_DIR/nginx.conf" "$RELDIR/nginx.conf"
for f in "$DEPLOY_DIR"/.env.*; do cp "$f" "$RELDIR/"; done
mkdir -p "$RELDIR/firmwares" "$RELDIR/images"
cp "$DEPLOY_DIR/images/logo.png" "$RELDIR/images/" 2>/dev/null || true

# Release compose file: drop the build: blocks and pin Oktopus images to the version tag.
SED_ARGS=()
for entry in "${OWN_SVCS[@]}"; do
  IFS='|' read -r svc img ctx <<< "$entry"
  SED_ARGS+=(-e "s|^([[:space:]]*image:[[:space:]]*)\"?${img}\"?[[:space:]]*\$|\\1${PREFIX}/${img##*/}:${VERSION}|")
done
awk '
  /^    build:[[:space:]]*$/ { skip=1; next }
  skip && /^      / { next }
  { skip=0; print }
' "$COMPOSE_SRC" | sed -E "${SED_ARGS[@]}" > "$RELDIR/docker-compose-release.yaml"

# The installer the recipient runs after untarring (700: only its owner can run or edit it).
cp "$INSTALL_SRC" "$RELDIR/install-release.sh"
chmod 700 "$RELDIR/install-release.sh"

sed -e "s/@VERSION_DATE@/${NAME}/g" -e "s/@VERSION@/${VERSION}/g" \
  "$NOTES_TEMPLATE" > "$RELDIR/ReleaseNotes.txt"

echo "==> packing $TARBALL"
tar -C "$OUTDIR" -czf "$TARBALL" "$NAME"

trap - ERR
echo "==> done"
echo "    $RELDIR/"
echo "    $TARBALL"
