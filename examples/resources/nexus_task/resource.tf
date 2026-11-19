resource "nexus_task" "compact_blobstore" {
  name                   = "Compact All Blobstores Daily"
  type                   = "blobstore.compact"
  enabled                = true
  notification_condition = "FAILURE"

  frequency {
    schedule        = "cron"
    cron_expression = "0 15 4 * * ?"
  }

  properties = {
    blobstoreName  = "(All Blob Stores)"
    blobsOlderThan = "3"
  }
}
