# Skydio fork notes

This is a Skydio fork of [datadrivers/terraform-provider-nexus](https://github.com/datadrivers/terraform-provider-nexus).

## Why a fork

Upstream lacks support for the **Alpine** repository format. We need it to proxy
Chainguard APK package repositories through Nexus, because the alternative
(raw proxy) doesn't send preemptive HTTP basic auth and Chainguard's APK
endpoint returns bare 401s without a `WWW-Authenticate` challenge — Nexus's
underlying Apache HttpClient won't transmit credentials in that case.

The Alpine proxy format does send preemptive auth and also handles APKINDEX
rebuild/caching automatically, which a raw proxy can't.

This fork adds:

- `nexus_repository_alpine_proxy` resource and data source
- A pinned dependency on [Skydio/go-nexus-client](https://github.com/Skydio/go-nexus-client)
  via a `replace` directive in `go.mod` (the underlying Go client also lacks
  Alpine support upstream)

Both changes have been opened as PRs against their respective upstreams. Once
merged + tagged, the `replace` directive can be removed.

## Publishing to Harbor

The provider is published to Harbor (`harbor.core.skyd.io`) as an OCI artifact
that bundles a Terraform `network_mirror`-compatible directory tree.

### One-time prerequisites

- `oras` >= 1.0 (`go install oras.land/oras/cmd/oras@latest`)
- `go` matching the version in `go.mod`
- `zip`, `shasum` (standard on macOS / Linux)
- Harbor credentials with push access to the `skyops` project

### Publish a new version

```bash
export HARBOR_USER=<your harbor username>
export HARBOR_PASS=<your harbor cli password / robot token>
export PROVIDER_VERSION=2.8.1-skydio.1   # bump as needed

./scripts/publish-to-harbor.sh
```

The script will:

1. Build the provider for `linux_{amd64,arm64}` and `darwin_{amd64,arm64}`
2. Zip each binary in the format Terraform expects
3. Generate `index.json` and `<version>.json` mirror metadata
4. Compute SHA-256 hashes for each archive
5. Push the entire tree as a single OCI artifact:
   `harbor.core.skyd.io/skyops/terraform-provider-nexus:<version>` (and
   re-tag `:latest`)

### Consuming from skyops

In the Terraform module that manages Nexus:

```bash
# 1. Pull the artifact into a local mirror directory (run by Atlantis / CI)
oras pull harbor.core.skyd.io/skyops/terraform-provider-nexus:2.8.1-skydio.1 \
  --output /tmp/tf-nexus-mirror

# 2. Configure Terraform to use it
cat > .terraformrc <<'EOF'
provider_installation {
  filesystem_mirror {
    path    = "/tmp/tf-nexus-mirror"
    include = ["registry.terraform.io/skydio/nexus"]
  }
  direct {
    exclude = ["registry.terraform.io/skydio/nexus"]
  }
}
EOF

export TF_CLI_CONFIG_FILE="$(pwd)/.terraformrc"
```

In `providers.tf`:

```hcl
terraform {
  required_providers {
    nexus = {
      source  = "skydio/nexus"
      version = "2.8.1-skydio.1"
    }
  }
}
```

### Future: native OCI mirror (Terraform 1.10+)

Terraform 1.10 added a native `oci_mirror` block for `provider_installation`,
which removes the need for the `oras pull` step. When skyops is on
Terraform >= 1.10:

```hcl
provider_installation {
  oci_mirror {
    repository_template = "harbor.core.skyd.io/skyops/{namespace}/{type}"
    include             = ["registry.terraform.io/skydio/*"]
  }
}
```
