resource "nexus_repository_go_hosted" "internal" {
  name   = "go-internal"
  online = true

  storage {
    blob_store_name                = "default"
    strict_content_type_validation = false
    write_policy                   = "ALLOW"
  }

}
