# The project's email integration (the account's own address by default).
data "healthchecksio_channel" "email" {
  kind = "email"
}

# Dead man's switch for the alerting pipeline: Alertmanager posts the
# always-firing Watchdog alert here every minute. When the posts stop
# (cluster, VictoriaMetrics stack or the internet uplink down) Healthchecks
# mails from the outside.
resource "healthchecksio_check" "watchdog" {
  name = "homelab-watchdog"
  desc = "Watchdog alert from the homelab Alertmanager, posted every minute"
  tags = ["homelab", "alertmanager"]

  timeout = 5 * 60
  grace   = 5 * 60
  # Alertmanager's webhook only POSTs; a GET (link preview, crawler) must
  # not count as a ping
  methods = "POST"

  channels = [data.healthchecksio_channel.email.id]
}
