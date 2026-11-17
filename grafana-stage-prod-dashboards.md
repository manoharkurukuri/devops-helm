# Grafana dashboards for staging and production

Create two dashboards matching the completed development dashboard:

| Environment | Namespace | Dashboard name |
| --- | --- | --- |
| Development (already completed; leave unchanged) | `devops-app` | Existing development dashboard |
| Staging | `devops-app-stage` | `DevOps App - Staging - Frontend and Backend` |
| Production | `devops-app-prod` | `DevOps App - Production - Frontend and Backend` |

This guide configures monitoring dashboards, not application deployment or HTTPS
provisioning. Both environments use deployments named `fullstack-frontend` and
`fullstack-backend`, and a certificate named `notes-app-certificate`.

## 1. Verified prerequisites

Checked against Kubernetes context `local` on November 17, 2026:

- Both environments have one ready frontend replica and one ready backend replica.
- Prometheus already collects deployment, restart, CPU, memory, and network metrics.
- Both application certificates are ready, and their metrics are already collected.
- The shared `monitoring/cert-manager` ServiceMonitor covers certificates in both
  namespaces. Do not create another ServiceMonitor for each application namespace.
- Grafana already has the `Prometheus` data source.

**Important production caveat:** the staging Gateway reported `Programmed=True`,
but the production Gateway reported `Programmed=False` at verification time.
The dashboards can still show resource and certificate metrics. A green
certificate panel does not prove production HTTPS works. Investigate the
production Gateway separately; this guide does not change it.

Read-only checks, if needed:

```bash
kubectl --context=local -n devops-app-stage get deployments,certificates
kubectl --context=local -n devops-app-prod get deployments,certificates
kubectl --context=local -n monitoring get servicemonitor cert-manager
kubectl --context=local -n devops-app-stage get gateway fullstack-gateway
kubectl --context=local -n devops-app-prod describe gateway fullstack-gateway
```

## 2. Common Grafana settings

Use these settings for BOTH dashboards.

### Dashboard time settings

1. At the top-right, open the time picker.
2. Select **Last 1 hour**, ending at **Now**.
3. Set automatic refresh to **30s**.
4. Do not reuse a fixed time range from an older dashboard URL.

### Adding each panel

1. Select **Add -> Visualization** (or **Add visualization**).
2. Select the **Prometheus** data source.
3. Under query **A**, select **Code**, not Builder.
4. Paste the PromQL into the code editor, NOT the Metrics browser/search field.
5. Under the panel's **Query options**, leave **Relative time** and **Time shift**
   blank. Leave Max data points and Min interval at their defaults.
6. Under query A's **Options**, set **Type** using the table below.
7. Click **Run queries**.
8. Choose the visualization under **All visualizations**, if necessary.
9. Set the title, legend, units, and thresholds.
10. Click **Apply / Back to dashboard / Back**, depending on Grafana version.
11. Click **Save dashboard / Save** and confirm the save dialog if shown.

Save after EACH panel so a reload does not lose your work.

### Panel configuration reference

Threshold mode should be **Absolute**, not Percentage.
For Stat panels, use **Last not null** if a calculation is requested.
For time-series panels, set the minimum axis value to `0`.

| Panel | Title | Visualization / query type | Legend | Unit / decimals | Thresholds |
| --- | --- | --- | --- | --- | --- |
| 1 | Available Replicas | Stat / Instant | `{{deployment}}` | None / 0 | Base red; 1 green |
| 2 | Deployment Availability | Stat / Instant | `{{deployment}}` | Percent (0-100) / 0 | Base red; 100 green |
| 3 | Container Restarts - Last 1h | Stat / Instant | `{{container}}` | None / 0 | Base green; 1 orange; 3 red |
| 4 | CPU Usage - Frontend vs Backend | Time series / Range | `{{container}}` | Custom `suffix: cores` | Not required |
| 5 | Memory Usage - Frontend vs Backend | Time series / Range | `{{container}}` | Bytes (IEC) | Not required |
| 6 | Pod Network Traffic | Time series / Range | See query A/B below | Bytes/sec | Not required |
| 7 | HTTPS Certificate Ready | Stat / Instant | `{{name}}` | None / 0 | Base red; 1 green |
| 8 | HTTPS Certificate - Days Remaining | Stat / Instant | `{{name}}` | Custom `suffix: days` / 1 | Base red; 3 orange; 10 green |

For panels 1, 2, 3, 7, and 8, set **Color mode** to **Value** or **Background**
to display threshold colors.

For panel 7, add value mappings:

- `1` -> `Ready`
- `0` -> `Not Ready`

Do not map missing data to `Ready` or zero. Missing metrics are not proof of health.

## 3. Staging dashboard: devops-app-stage

### 3.1 Create and save the dashboard

1. Open **Dashboards -> New -> New dashboard**.
2. Add the first visualization using the procedure in section 2.
3. Use the panel 1 query below and save the dashboard as:
   **DevOps App - Staging - Frontend and Backend**.
4. Add panels 2-8 using the queries below and the shared configuration table.
5. Keep the time picker at **Last 1 hour** and save after each panel.

### 3.2 Panel 1: Available Replicas

```promql
kube_deployment_status_replicas_available{
  namespace="devops-app-stage",
  deployment=~"fullstack-(frontend|backend)"
}
```

Expected with the current configuration: frontend `1`, backend `1`.

### 3.3 Panel 2: Deployment Availability

```promql
100 *
kube_deployment_status_replicas_available{
  namespace="devops-app-stage",
  deployment=~"fullstack-(frontend|backend)"
}
/
kube_deployment_spec_replicas{
  namespace="devops-app-stage",
  deployment=~"fullstack-(frontend|backend)"
}
```

Expected: `100%` for each deployment when all desired replicas are available.

### 3.4 Panel 3: Container Restarts - Last 1h

```promql
sum by (container) (
  increase(
    kube_pod_container_status_restarts_total{
      namespace="devops-app-stage",
      pod=~"fullstack-(frontend|backend)-.*",
      container=~"frontend|backend"
    }[1h]
  )
)
```

### 3.5 Panel 4: CPU Usage - Frontend vs Backend

```promql
sum by (container) (
  rate(
    container_cpu_usage_seconds_total{
      namespace="devops-app-stage",
      pod=~"fullstack-(frontend|backend)-.*",
      container=~"frontend|backend",
      job="kubelet",
      metrics_path="/metrics/cadvisor"
    }[$__rate_interval]
  )
)
```

### 3.6 Panel 5: Memory Usage - Frontend vs Backend

```promql
sum by (container) (
  container_memory_working_set_bytes{
    namespace="devops-app-stage",
    pod=~"fullstack-(frontend|backend)-.*",
    container=~"frontend|backend",
    job="kubelet",
    metrics_path="/metrics/cadvisor"
  }
)
```

### 3.7 Panel 6: Pod Network Traffic

Query A, with legend `{{pod}} receive`:

```promql
sum by (pod) (
  rate(
    container_network_receive_bytes_total{
      namespace="devops-app-stage",
      pod=~"fullstack-(frontend|backend)-.*",
      job="kubelet",
      metrics_path="/metrics/cadvisor"
    }[$__rate_interval]
  )
)
```

Click **Add query** in the SAME panel. Select Prometheus and Code for query B.
Set both queries to **Range**.

Query B, with legend `{{pod}} transmit`:

```promql
sum by (pod) (
  rate(
    container_network_transmit_bytes_total{
      namespace="devops-app-stage",
      pod=~"fullstack-(frontend|backend)-.*",
      job="kubelet",
      metrics_path="/metrics/cadvisor"
    }[$__rate_interval]
  )
)
```

### 3.8 Panel 7: HTTPS Certificate Ready

```promql
certmanager_certificate_ready_status{
  namespace="devops-app-stage",
  name="notes-app-certificate",
  condition="True"
}
```

Expected: `1`, displayed as `Ready` after applying the value mapping.
`True` is case-sensitive.

### 3.9 Panel 8: HTTPS Certificate - Days Remaining

```promql
(
  certmanager_certificate_expiration_timestamp_seconds{
    namespace="devops-app-stage",
    name="notes-app-certificate"
  } - time()
) / 86400
```

The result is remaining days, not a Unix timestamp.
Use **Stat**, **Instant**, and one decimal place.

### 3.10 Save and verify staging

1. Arrange the panels using section 5.
2. Save the dashboard.
3. Reload the page.
4. Confirm all eight panels remain and display staging data.
5. Inspect each query's namespace: it must be exactly `devops-app-stage`.
   Panel 6 has TWO queries to check.

## 4. Production dashboard: devops-app-prod

### 4.1 Create and save a separate dashboard

1. Open **Dashboards -> New -> New dashboard**.
2. Add the first visualization using the procedure in section 2.
3. Use the panel 1 query below and save the dashboard as:
   **DevOps App - Production - Frontend and Backend**.
4. Add panels 2-8 using the queries below and the shared configuration table.
5. Keep the time picker at **Last 1 hour** and save after each panel.

Do not overwrite the development or staging dashboard.

### 4.2 Panel 1: Available Replicas

```promql
kube_deployment_status_replicas_available{
  namespace="devops-app-prod",
  deployment=~"fullstack-(frontend|backend)"
}
```

Expected with the current configuration: frontend `1`, backend `1`.

### 4.3 Panel 2: Deployment Availability

```promql
100 *
kube_deployment_status_replicas_available{
  namespace="devops-app-prod",
  deployment=~"fullstack-(frontend|backend)"
}
/
kube_deployment_spec_replicas{
  namespace="devops-app-prod",
  deployment=~"fullstack-(frontend|backend)"
}
```

Expected: `100%` for each deployment when all desired replicas are available.

### 4.4 Panel 3: Container Restarts - Last 1h

```promql
sum by (container) (
  increase(
    kube_pod_container_status_restarts_total{
      namespace="devops-app-prod",
      pod=~"fullstack-(frontend|backend)-.*",
      container=~"frontend|backend"
    }[1h]
  )
)
```

### 4.5 Panel 4: CPU Usage - Frontend vs Backend

```promql
sum by (container) (
  rate(
    container_cpu_usage_seconds_total{
      namespace="devops-app-prod",
      pod=~"fullstack-(frontend|backend)-.*",
      container=~"frontend|backend",
      job="kubelet",
      metrics_path="/metrics/cadvisor"
    }[$__rate_interval]
  )
)
```

### 4.6 Panel 5: Memory Usage - Frontend vs Backend

```promql
sum by (container) (
  container_memory_working_set_bytes{
    namespace="devops-app-prod",
    pod=~"fullstack-(frontend|backend)-.*",
    container=~"frontend|backend",
    job="kubelet",
    metrics_path="/metrics/cadvisor"
  }
)
```

### 4.7 Panel 6: Pod Network Traffic

Query A, with legend `{{pod}} receive`:

```promql
sum by (pod) (
  rate(
    container_network_receive_bytes_total{
      namespace="devops-app-prod",
      pod=~"fullstack-(frontend|backend)-.*",
      job="kubelet",
      metrics_path="/metrics/cadvisor"
    }[$__rate_interval]
  )
)
```

Click **Add query** in the SAME panel. Select Prometheus and Code for query B.
Set both queries to **Range**.

Query B, with legend `{{pod}} transmit`:

```promql
sum by (pod) (
  rate(
    container_network_transmit_bytes_total{
      namespace="devops-app-prod",
      pod=~"fullstack-(frontend|backend)-.*",
      job="kubelet",
      metrics_path="/metrics/cadvisor"
    }[$__rate_interval]
  )
)
```

### 4.8 Panel 7: HTTPS Certificate Ready

```promql
certmanager_certificate_ready_status{
  namespace="devops-app-prod",
  name="notes-app-certificate",
  condition="True"
}
```

Expected: `1`, displayed as `Ready` after applying the value mapping.
This does not override the production Gateway warning in section 1.

### 4.9 Panel 8: HTTPS Certificate - Days Remaining

```promql
(
  certmanager_certificate_expiration_timestamp_seconds{
    namespace="devops-app-prod",
    name="notes-app-certificate"
  } - time()
) / 86400
```

Use **Stat**, **Instant**, and one decimal place.

### 4.10 Save and verify production

1. Arrange the panels using section 5.
2. Save the dashboard.
3. Reload the page.
4. Confirm all eight panels remain and display production data.
5. Inspect each query's namespace: it must be exactly `devops-app-prod`.
   Panel 6 has TWO queries to check.

## 5. Recommended layout for both dashboards

```text
Application Health
[ Available Replicas ] [ Deployment Availability ] [ Restarts - Last 1h ]

Resource Usage
[ CPU Usage                       ] [ Memory Usage                     ]

Network
[ Pod Network Traffic                                                  ]

HTTPS Certificates
[ Certificate Ready               ] [ Certificate Days Remaining       ]
```

Use **Add -> Row** if you want collapsible section headings. Drag and resize
panels into position, then save again.

## 6. Interpreting the panels correctly

- **Replicas:** the threshold of 1 matches the current one-replica configuration.
  If you scale up, use Deployment Availability to judge whether ALL desired
  replicas are available.
- **Availability:** 100% means available replicas equal desired replicas.
  A deployment scaled to zero has no meaningful availability percentage.
  This metric is not an HTTP uptime measurement.
- **Restarts:** `increase(...[1h])` estimates container counter changes over the
  last hour and can produce fractional results. Pod replacements are not counted
  as container restarts.
- **CPU:** values are cores summed by component across its pods.
  `0.1` cores equals 100 millicores. This is not percent of the CPU limit.
- **Memory:** working-set bytes summed by component, displayed automatically in
  units such as MiB.
- **Network:** pod traffic, not HTTP request counts. Do not add the application
  container filter to these pod network queries.
- **Certificate expiry:** both certificates are configured for 30-day validity
  and renewal 10 days before expiration. Remaining days increase after renewal.
- **HTTPS:** certificate readiness does not check Gateway routing, endpoint
  reachability, the certificate actually served, or browser trust of the local CA.
  End-to-end HTTPS checks require a probe such as Blackbox Exporter configured
  to trust the CA. Do not disable TLS verification to hide trust failures.

## 7. Troubleshooting "No data"

### A. Check time before changing infrastructure

1. Set the TOP dashboard time picker to **Last 1 hour**, ending at **Now**.
2. Clear the panel's **Relative time** and **Time shift**.
3. Use **Instant** for Stat panels and **Range** for time-series panels.
4. Run the query again.

Changing Type to Instant does not reset the dashboard end time. An old fixed
end time still queries old data. Newly enabled metrics do not exist historically
before collection began.

### B. Check the query editor and namespace

- Data source must be **Prometheus**.
- Paste expressions into **Code**, not metric search.
- "Could not find anything matching your query" in search/autocomplete is not
  necessarily a Prometheus execution error. Press Escape to dismiss suggestions,
  then click **Run queries**.
- Staging is exactly `devops-app-stage`, with NO trailing period.
- Production is exactly `devops-app-prod`.
- Certificate name is `notes-app-certificate`; readiness condition is `True`.

### C. Test in Grafana Explore

Open **Explore -> Prometheus**, select a current time range, and run:

```promql
certmanager_certificate_ready_status{
  namespace=~"devops-app-(stage|prod)",
  name="notes-app-certificate",
  condition="True"
}
```

Expected: two series, one per namespace, each `1` while ready.

Then test expiration:

```promql
(
  certmanager_certificate_expiration_timestamp_seconds{
    namespace=~"devops-app-(stage|prod)",
    name="notes-app-certificate"
  } - time()
) / 86400
```

Expected: two values showing remaining days.

If Explore works but a panel does not, inspect panel time overrides, query
visibility, transformations, and data source. Start with no transformations.

### D. Test in the Prometheus UI

If your existing local port-forward is running, open:

```text
http://localhost:9090/query
```

Use a current evaluation time, paste the query, choose **Table**, and click
**Execute**. Avoid old bookmarked URLs containing fixed evaluation timestamps.

Grafana's `$__rate_interval` is not valid directly in Prometheus. When testing
CPU/network expressions there, replace `[$__rate_interval]` with `[2m]`.

If a local Prometheus connection is needed, run this in a separate terminal
and keep it open. Do not start it if port 9090 is already in use:

```bash
kubectl --context=local -n monitoring port-forward \
  svc/prometheus-kube-prometheus-prometheus 9090:9090
```

### E. Check certificate collection only if the current query is empty

Run in Explore:

```promql
up{namespace="cert-manager",service="cert-manager"}
```

- `1`: scraping succeeds.
- `0`: the discovered target cannot be scraped; inspect its error on the
  Prometheus Targets page.
- No data: inspect ServiceMonitor selection/discovery and the selected data source.

The existing shared ServiceMonitor uses `honorLabels: true` to preserve the
certificate's application namespace. Do not replace it or duplicate it merely
because a dashboard panel is empty.

For Grafana connectivity checks, the configured Prometheus data source URL is:

```text
http://prometheus-kube-prometheus-prometheus.monitoring:9090/
```

Under **Connections -> Data sources -> Prometheus**, use **Save & test**.
Do not change the Grafana data source to `localhost:9090`: Grafana runs inside
Kubernetes, where localhost is not your workstation.

## 8. Completion checklist

- [ ] Development dashboard remains unchanged.
- [ ] Staging dashboard is saved with all eight panels.
- [ ] Production dashboard is saved with all eight panels.
- [ ] Both dashboards use Last 1 hour, ending at Now, and refresh every 30s.
- [ ] Panel Relative time and Time shift overrides are blank.
- [ ] Every query uses its dashboard's namespace, including both network queries.
- [ ] Both certificate panels show Ready and positive days remaining.
- [ ] Reloading each dashboard preserves the saved panels.
- [ ] Production Gateway health is assessed separately from certificate readiness.

Saving a dashboard persists it in Grafana's database. Durability across Grafana
replacement depends on its database/storage configuration. For an additional
backup, use Grafana's **Export / Export as JSON** option for each saved dashboard
(the menu location varies by version).
