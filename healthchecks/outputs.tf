# Written to the Secret healthchecks-outputs (writeOutputsToSecret), which the
# VMAlertmanager mounts and reads as the webhook's url_file.
output "ping_url" {
  value = healthchecksio_check.watchdog.ping_url
}
