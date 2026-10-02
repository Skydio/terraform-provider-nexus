resource "nexus_repository_go_hosted" "internal" {
  name   = "go-internal"
  online = true

  storage {
    blob_store_name                = "default"
    strict_content_type_validation = false
    # Go module versions must be immutable once published (the go.sum
    # checksum database assumes a given module@version never changes).
    write_policy = "ALLOW_ONCE"
  }

}
