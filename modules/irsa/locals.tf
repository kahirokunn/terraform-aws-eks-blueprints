locals {
  timeouts = {
    create = lookup(var.timeouts, "create", "10m")
  }
}
