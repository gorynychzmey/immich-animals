#!/usr/bin/env bash
# Build, smoke-test and push the OpenVINO sidecar image. CI calls this; run it
# locally with the same env to reproduce a CI build.
#
#   IMAGE_REPO=ghcr.io/gorynychzmey/animal-ml-openvino VERSION_OVERRIDE=0.3.0 ./build.sh
set -euo pipefail

ENGINE="${CONTAINER_ENGINE:-podman}"
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/gorynychzmey/animal-ml-openvino}"
USE_BUILDX="${USE_BUILDX:-auto}"
BUILDX_CACHE_REPO="${BUILDX_CACHE_REPO:-${IMAGE_REPO}}"
BUILDX_CACHE_MODE="${BUILDX_CACHE_MODE:-max}"
PUSH="${PUSH:-true}"
VERSION="${VERSION_OVERRIDE:-$(sed -n 's/^version = "\(.*\)"/\1/p' sidecar/pyproject.toml)}"

if ! [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid version '${VERSION}'. Expected semver: X.Y.Z"
  exit 1
fi

IMAGE="${IMAGE_REPO}:${VERSION}"
LATEST="${IMAGE_REPO}:latest"
build_args=(-f sidecar/Dockerfile --build-arg VARIANT=openvino -t "${IMAGE}" -t "${LATEST}")

use_buildx=false
if [[ "${ENGINE}" == "docker" && "${USE_BUILDX}" != "false" ]] && docker buildx version >/dev/null 2>&1; then
  use_buildx=true
elif [[ "${USE_BUILDX}" == "true" ]]; then
  echo "USE_BUILDX=true but docker buildx is not available"
  exit 1
fi

echo "Building ${IMAGE}"
if [[ "${use_buildx}" == "true" ]]; then
  docker buildx build "${build_args[@]}" \
    --cache-from "type=registry,ref=${BUILDX_CACHE_REPO}:buildcache" \
    --cache-to "type=registry,ref=${BUILDX_CACHE_REPO}:buildcache,mode=${BUILDX_CACHE_MODE}" \
    --load .
else
  "${ENGINE}" build "${build_args[@]}" .
fi

# A runner has no Intel GPU, so the smoke test loads the models on OpenVINO's
# CPU device: it proves the image, the provider and the Immich contract, not
# GPU speed.
smoke="animal-ml-smoke-$$"
trap '"${ENGINE}" rm -f "${smoke}" >/dev/null 2>&1 || true' EXIT
"${ENGINE}" run -d --name "${smoke}" \
  -e OPENVINO_DEVICE=CPU -e KEEP_HUMAN_FACES=false \
  -v "${PWD}/sidecar/smoke_test.py:/smoke_test.py:ro" \
  "${IMAGE}" >/dev/null
for _ in $(seq 60); do
  "${ENGINE}" exec "${smoke}" python -c \
    "import httpx; httpx.get('http://localhost:3003/ping').raise_for_status()" \
    >/dev/null 2>&1 && break
  sleep 2
done
"${ENGINE}" exec "${smoke}" python -c \
  "import cv2, numpy as np; cv2.imwrite('/tmp/blank.jpg', np.full((240, 320, 3), 128, np.uint8))"
"${ENGINE}" exec "${smoke}" python /smoke_test.py /tmp/blank.jpg --url http://localhost:3003
logs="$("${ENGINE}" logs "${smoke}" 2>&1)"
if [[ "${logs}" != *"animal-ml: OpenVINOExecutionProvider"* ]]; then
  echo "Sidecar did not start on the OpenVINO provider"
  echo "${logs}"
  exit 1
fi

if [[ "${PUSH}" == "true" ]]; then
  echo "Pushing ${IMAGE} and ${LATEST}"
  "${ENGINE}" push "${IMAGE}"
  "${ENGINE}" push "${LATEST}"
fi
