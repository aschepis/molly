# Remote Prometheus, remote_write, and fleets

Molly is pull-only: it serves `/metrics` and something scrapes it. Three
setups move the data off this machine.

## 1. Scrape Molly from a Prometheus on another machine

By default Molly binds `127.0.0.1`, so only the local Docker stack can reach
it. To let a remote Prometheus scrape it, bind a reachable address in
`~/Library/Application Support/Molly/config.json`:

```json
{
  "server": { "bind": "100.64.0.12", "port": 9765 },
  "events": { "token": "a-long-random-string" }
}
```

What to know before you do:

- `/metrics` has no authentication. Bind to a VPN or Tailscale address, not
  `0.0.0.0`, and firewall port 9765 to the scraping host. Labels can carry app
  names, repo names and (if you enabled the policies) domains and hosts.
- `POST /event` accepts pushes from anyone who can reach the port. Set
  `events.token`; `molly hook` sends it automatically.
- `/config`, `/collectors`, `/privacy`, `/stats` and `/insights/*` are served
  on the same port. They contain no secrets (salts, API keys and tokens are
  redacted) but they describe your setup.

Remote `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: molly
    honor_labels: true
    scrape_interval: 15s
    static_configs:
      - targets:
          - "my-mac.tailnet.example:9765"
          - "work-mac.tailnet.example:9765"
```

`honor_labels: true` keeps Molly's `user` and `host` labels. Copy
`deploy/prometheus/rules/molly.yml` to the remote Prometheus so the recording
rules and alerts the dashboards use exist there too, and import
`deploy/grafana/dashboards/*.json` into that Grafana with a datasource whose
uid is `molly-prometheus` (or edit the uid in the JSON).

## 2. remote_write from the local stack

Keep scraping locally and let the local Prometheus forward its copy to a
hosted backend (Grafana Cloud, or a home server running Prometheus, Mimir or
VictoriaMetrics). `deploy/prometheus/prometheus.yml` ends with a commented
`remote_write` block:

```yaml
remote_write:
  - url: https://prometheus-prod-XX-prod-us-east-0.grafana.net/api/prom/push
    basic_auth:
      username: "123456"
      password_file: /etc/prometheus/remote_write_token
    write_relabel_configs:
      - source_labels: [job]
        regex: molly
        action: keep
```

Prometheus does not substitute environment variables inside its config file,
so either paste the values in (and keep the file out of git) or render it
from a template before `docker compose up`. Mount the token as a file and
reference it with `password_file` rather than writing it into the YAML. The
`write_relabel_configs` block ships Molly's series only; drop it to forward
the Prometheus self-metrics as well. Reload with
`curl -X POST localhost:9090/-/reload` after editing.

Grafana Cloud's free tier counts active series; Molly produces about a
thousand per machine with the default policies. `molly tune` reports the
largest families if you need to trim.

## 3. Several machines, one Prometheus

Every Molly series carries `user` and `host`, so any number of machines can
share one Prometheus through either setup above. The dashboards' `$user` and
`$host` selectors pick a machine (or All), and the **Molly / Fleet**
dashboard shows them side by side: liveness, version, who is active now,
focused app, battery, CPU, memory pressure, collectors failing, and per-host
active hours, commits and Claude cost.

Give each machine a stable `host` label if hostnames change on different
networks:

```json
{ "labels": { "host": "laptop", "extra": { "site": "home" } } }
```

## Retention, backup, prune

- Local retention is `PROMETHEUS_RETENTION` (default `2y`) in
  `deploy/docker-compose.yml`.
- `molly export` snapshots the TSDB through the admin API and tars it with
  config, cursors and insights. `molly export --restore <tarball>` prints the
  manual restore steps.
- `molly prune --older-than 90d` deletes Molly samples older than the cutoff
  (`--dry-run` first). Both need `--web.enable-admin-api`, which the compose
  file sets; do not expose port 9090 beyond this machine with that flag on.
