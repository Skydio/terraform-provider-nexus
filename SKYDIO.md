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

## Publishing to Nexus

The provider is published to a Skydio-hosted Nexus raw repository
(`https://nexus.skyd.io/repository/terraform-providers/`) in the layout that
Terraform's [network_mirror protocol][network-mirror] expects. Because that
protocol is plain HTTPS, consumers get the provider directly from Terraform's
own provider installer — no `oras` / `docker` / extra tooling needed.

[network-mirror]: https://developer.hashicorp.com/terraform/internals/provider-network-mirror-protocol

### One-time prerequisites

- `go` matching the version in `go.mod`
- `zip`, `shasum`, `curl`, `jq` (standard on macOS / Linux)
- A Nexus user token with write access to the `terraform-providers` repo.
  Generate one at <https://nexus.skyd.io/#user/usertoken> and use the
  `<name>:<passcode>` pair.

### Publish a new version

```bash
export NEXUS_USER=<your nexus user-token name>
export NEXUS_PASS=<your nexus user-token passcode>
export PROVIDER_VERSION=2.8.1-skydio.1   # bump as needed

./scripts/publish-to-nexus.sh
```

The script will:

1. Build the provider for `linux_{amd64,arm64}` and `darwin_{amd64,arm64}`.
2. Zip each binary in the format Terraform's mirror protocol expects.
3. Fetch the existing `index.json` (if any) and merge in the new version, so
   previously published versions remain reachable.
4. Compute SHA-256 hashes for each archive and emit the per-version JSON.
5. `PUT` everything to
   `https://nexus.skyd.io/repository/terraform-providers/registry.terraform.io/skydio/nexus/`.

### Consuming from skyops

Drop a `.terraformrc` in the directory whose `providers.tf` references this
provider, and point Terraform at it via `TF_CLI_CONFIG_FILE`:

```hcl
# .terraformrc
provider_installation {
  network_mirror {
    url = "https://nexus.skyd.io/repository/terraform-providers/"
  }
  direct {
    exclude = ["registry.terraform.io/skydio/*"]
  }
}
```

```hcl
# providers.tf
terraform {
  required_providers {
    nexus = {
      source  = "skydio/nexus"
      version = "2.8.1-skydio.1"
    }
  }
}
```

`terraform init` fetches the provider directly from Nexus over HTTPS. Atlantis
already has network access to `nexus.skyd.io`, so no image rebuild or pre-init
hook is required.

The repository declaration lives at
[`terraform/nexus/terraform-providers/`](https://github.com/Skydio/skyops/tree/master/terraform/nexus/terraform-providers)
in skyops.
