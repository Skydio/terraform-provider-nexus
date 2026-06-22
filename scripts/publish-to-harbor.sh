#!/usr/bin/env bash
# Publish the Skydio fork of terraform-provider-nexus to Harbor as an OCI
# provider mirror. The mirror is consumable from Terraform 1.10+ via the
# `oci_mirror` provider_installation method, and the raw zips are also pushed
# as a generic OCI artifact so older Terraform versions can pull them via
# `oras` + `filesystem_mirror`.
#
# Required env:
#   HARBOR_HOST       - default harbor.core.skyd.io
#   HARBOR_PROJECT    - default skyops
#   HARBOR_USER       - Harbor username (or use docker login beforehand)
#   HARBOR_PASS       - Harbor password (or use docker login beforehand)
#   PROVIDER_VERSION  - semver, e.g. 2.8.1-skydio.1
#
# Run from the repo root:
#   ./scripts/publish-to-harbor.sh
set -euo pipefail

HARBOR_HOST="${HARBOR_HOST:-harbor.core.skyd.io}"
HARBOR_PROJECT="${HARBOR_PROJECT:-skyops}"
PROVIDER_NAME="terraform-provider-nexus"
PROVIDER_NAMESPACE="skydio"
PROVIDER_VERSION="${PROVIDER_VERSION:?PROVIDER_VERSION is required (e.g. 2.8.1-skydio.1)}"

# Platforms to build. Add more as needed.
PLATFORMS=(
	"linux_amd64"
	"linux_arm64"
	"darwin_amd64"
	"darwin_arm64"
)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist/harbor-publish"
mkdir -p "${DIST_DIR}"

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "error: $1 not installed" >&2
		exit 1
	}
}

require_cmd go
require_cmd zip
require_cmd shasum
require_cmd oras

if [[ -n "${HARBOR_USER:-}" && -n "${HARBOR_PASS:-}" ]]; then
	echo "==> Logging in to ${HARBOR_HOST} as ${HARBOR_USER}"
	echo "${HARBOR_PASS}" | oras login "${HARBOR_HOST}" --username "${HARBOR_USER}" --password-stdin
fi

build_platform() {
	local platform="$1"
	local goos="${platform%_*}"
	local goarch="${platform#*_}"
	local binary="${PROVIDER_NAME}_v${PROVIDER_VERSION}"
	[[ "${goos}" == "windows" ]] && binary="${binary}.exe"

	local outdir="${DIST_DIR}/${platform}"
	mkdir -p "${outdir}"

	echo "==> Building ${platform}"
	(cd "${REPO_ROOT}" && \
		CGO_ENABLED=0 GOOS="${goos}" GOARCH="${goarch}" \
		go build \
		-trimpath \
		-ldflags "-s -w -X main.version=${PROVIDER_VERSION}" \
		-o "${outdir}/${binary}" .)

	local zip_name="${PROVIDER_NAME}_${PROVIDER_VERSION}_${platform}.zip"
	(cd "${outdir}" && zip -q "${DIST_DIR}/${zip_name}" "${binary}")
	echo "    -> ${zip_name}"
}

write_shasums() {
	local sha_file="${DIST_DIR}/${PROVIDER_NAME}_${PROVIDER_VERSION}_SHA256SUMS"
	(cd "${DIST_DIR}" && shasum -a 256 ${PROVIDER_NAME}_${PROVIDER_VERSION}_*.zip > "${sha_file}")
	echo "==> Wrote ${sha_file}"
	cat "${sha_file}"
}

generate_mirror_metadata() {
	# Generates Terraform network_mirror v1 metadata (index.json + per-version JSON).
	# These describe which platforms exist and the URLs to download them.
	local mirror_dir="${DIST_DIR}/mirror/registry.terraform.io/${PROVIDER_NAMESPACE}/nexus"
	mkdir -p "${mirror_dir}"

	# index.json: list of available versions
	cat > "${mirror_dir}/index.json" <<EOF
{
  "versions": {
    "${PROVIDER_VERSION}": {}
  }
}
EOF

	# <version>.json: per-platform archives
	local version_json="${mirror_dir}/${PROVIDER_VERSION}.json"
	echo "{" > "${version_json}"
	echo "  \"archives\": {" >> "${version_json}"
	local first=1
	for platform in "${PLATFORMS[@]}"; do
		local zip_name="${PROVIDER_NAME}_${PROVIDER_VERSION}_${platform}.zip"
		local sha
		sha=$(shasum -a 256 "${DIST_DIR}/${zip_name}" | awk '{print $1}')
		if [[ ${first} -eq 0 ]]; then echo "    ," >> "${version_json}"; fi
		first=0
		cat >> "${version_json}" <<EOF
    "${platform}": {
      "url": "${zip_name}",
      "hashes": ["sha256:${sha}"]
    }
EOF
	done
	echo "  }" >> "${version_json}"
	echo "}" >> "${version_json}"
	echo "==> Generated mirror metadata in ${mirror_dir}"

	# Copy zips alongside the metadata so the mirror is self-contained.
	cp "${DIST_DIR}"/${PROVIDER_NAME}_${PROVIDER_VERSION}_*.zip "${mirror_dir}/"
}

push_to_harbor() {
	# Push the entire mirror/ tree as a single OCI artifact. Consumers can
	# `oras pull` it and point Terraform's filesystem_mirror at the result.
	local repo="${HARBOR_HOST}/${HARBOR_PROJECT}/${PROVIDER_NAME}"
	local tag="${PROVIDER_VERSION}"

	echo "==> Pushing OCI artifact to ${repo}:${tag}"
	(cd "${DIST_DIR}/mirror" && \
		oras push "${repo}:${tag}" \
			--artifact-type "application/vnd.skydio.terraform-provider-mirror.v1" \
			$(find . -type f -printf "%P:application/zip\n" | grep '\.zip$') \
			$(find . -type f -name '*.json' -printf "%P:application/json\n"))

	# Also tag as latest for convenience.
	oras tag "${repo}:${tag}" latest
	echo "==> Done. Pull with:"
	echo "    oras pull ${repo}:${tag} --output ./tf-mirror"
}

main() {
	rm -rf "${DIST_DIR}"
	mkdir -p "${DIST_DIR}"

	for platform in "${PLATFORMS[@]}"; do
		build_platform "${platform}"
	done

	write_shasums
	generate_mirror_metadata
	push_to_harbor
}

main "$@"
