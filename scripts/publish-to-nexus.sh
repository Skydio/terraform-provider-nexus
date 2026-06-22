#!/usr/bin/env bash
# Publish the Skydio fork of terraform-provider-nexus to a Nexus raw-hosted
# repository in the Terraform `network_mirror` layout. Consumers configure
# Terraform with a `network_mirror` block and Terraform fetches directly over
# HTTPS — no oras/docker/cli tooling needed on the consumer side.
#
# Required env:
#   NEXUS_USER        - Nexus username (or user-token name)
#   NEXUS_PASS        - Nexus password (or user-token passcode)
#   PROVIDER_VERSION  - semver, e.g. 2.8.1-skydio.1
# Optional env:
#   NEXUS_URL         - default https://nexus.skyd.io
#   NEXUS_REPO        - default terraform-providers
#   PROVIDER_NS       - default skydio
#
# Run from the repo root:
#   ./scripts/publish-to-nexus.sh
set -euo pipefail

NEXUS_URL="${NEXUS_URL:-https://nexus.skyd.io}"
NEXUS_REPO="${NEXUS_REPO:-terraform-providers}"
PROVIDER_NS="${PROVIDER_NS:-skydio}"
PROVIDER_NAME="terraform-provider-nexus"
PROVIDER_TYPE="nexus"
PROVIDER_VERSION="${PROVIDER_VERSION:?PROVIDER_VERSION is required (e.g. 2.8.1-skydio.1)}"

NEXUS_USER="${NEXUS_USER:?NEXUS_USER is required (Nexus username or user-token name)}"
NEXUS_PASS="${NEXUS_PASS:?NEXUS_PASS is required (Nexus password or user-token passcode)}"

# Platforms to build. Add more as needed.
PLATFORMS=(
	"linux_amd64"
	"linux_arm64"
	"darwin_amd64"
	"darwin_arm64"
)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist/nexus-publish"
MIRROR_BASE="${NEXUS_URL}/repository/${NEXUS_REPO}/registry.terraform.io/${PROVIDER_NS}/${PROVIDER_TYPE}"

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "error: $1 not installed" >&2
		exit 1
	}
}

require_cmd go
require_cmd zip
require_cmd shasum
require_cmd curl
require_cmd jq

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

generate_metadata() {
	# Mirror metadata files (index.json + per-version JSON) per
	# https://developer.hashicorp.com/terraform/internals/provider-network-mirror-protocol
	local mirror_dir="${DIST_DIR}/mirror"
	mkdir -p "${mirror_dir}"

	# Fetch existing index.json so we don't drop previously published versions.
	local existing_index="${mirror_dir}/_existing_index.json"
	if curl -sf -o "${existing_index}" "${MIRROR_BASE}/index.json"; then
		echo "==> Merging into existing index.json"
	else
		echo '{"versions":{}}' > "${existing_index}"
		echo "==> No existing index.json found; creating fresh"
	fi

	jq --arg v "${PROVIDER_VERSION}" '.versions[$v] = {}' "${existing_index}" \
		> "${mirror_dir}/index.json"

	# Build per-version archives map.
	local version_json="${mirror_dir}/${PROVIDER_VERSION}.json"
	local jq_args=()
	jq_args+=("-n")
	local archives_obj='{}'
	for platform in "${PLATFORMS[@]}"; do
		local zip_name="${PROVIDER_NAME}_${PROVIDER_VERSION}_${platform}.zip"
		local sha
		sha=$(shasum -a 256 "${DIST_DIR}/${zip_name}" | awk '{print $1}')
		archives_obj=$(jq -n \
			--argjson existing "${archives_obj}" \
			--arg platform "${platform}" \
			--arg url "${zip_name}" \
			--arg sha "sha256:${sha}" \
			'$existing + {($platform): {"url": $url, "hashes": [$sha]}}')
	done
	jq -n --argjson archives "${archives_obj}" '{archives: $archives}' \
		> "${version_json}"
	echo "==> Wrote ${version_json}"

	# Stage the zips alongside the metadata so the upload step is one loop.
	cp "${DIST_DIR}"/${PROVIDER_NAME}_${PROVIDER_VERSION}_*.zip "${mirror_dir}/"
}

upload_one() {
	local local_path="$1"
	local remote_path="$2"
	local url="${MIRROR_BASE}/${remote_path}"
	echo "    PUT ${url}"
	# --fail-with-body prints server response on failure (Nexus returns useful
	# errors when content type validation rejects a path, etc.).
	curl --fail-with-body -sS -u "${NEXUS_USER}:${NEXUS_PASS}" \
		--upload-file "${local_path}" "${url}" \
		|| { echo "error: upload failed for ${remote_path}" >&2; exit 1; }
}

upload_all() {
	echo "==> Uploading to ${MIRROR_BASE}/"
	upload_one "${DIST_DIR}/mirror/index.json" "index.json"
	upload_one "${DIST_DIR}/mirror/${PROVIDER_VERSION}.json" "${PROVIDER_VERSION}.json"
	for platform in "${PLATFORMS[@]}"; do
		local zip_name="${PROVIDER_NAME}_${PROVIDER_VERSION}_${platform}.zip"
		upload_one "${DIST_DIR}/mirror/${zip_name}" "${zip_name}"
	done
}

main() {
	rm -rf "${DIST_DIR}"
	mkdir -p "${DIST_DIR}"

	for platform in "${PLATFORMS[@]}"; do
		build_platform "${platform}"
	done

	generate_metadata
	upload_all

	cat <<EOF

==> Published ${PROVIDER_NAME} v${PROVIDER_VERSION}.

To verify:
    curl -s ${MIRROR_BASE}/index.json | jq

To consume in Terraform, add to .terraformrc:
    provider_installation {
      network_mirror {
        url = "${NEXUS_URL}/repository/${NEXUS_REPO}/"
      }
      direct {
        exclude = ["registry.terraform.io/${PROVIDER_NS}/*"]
      }
    }

And in providers.tf:
    terraform {
      required_providers {
        ${PROVIDER_TYPE} = {
          source  = "${PROVIDER_NS}/${PROVIDER_TYPE}"
          version = "${PROVIDER_VERSION}"
        }
      }
    }
EOF
}

main "$@"
