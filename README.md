# Prometheus + Blackbox Exporter DB Port Monitoring

Project ini memonitor availability port database dengan TCP probe:

- Blackbox Exporter melakukan connect ke `host:port`.
- Prometheus scrape hasil probe setiap 10 detik.
- Grafana membaca metric dari Prometheus.
- Tidak ada credential database target yang disimpan atau dipakai.

## Service

Service Docker:

- `prometheus`
- `blackbox-exporter`
- `blackbox-pg-writer`

Port UI hanya bind ke localhost server:

- Prometheus: `http://127.0.0.1:9090`
- Blackbox Exporter: `http://127.0.0.1:9115`

Keduanya join external network `grafana_default`, sehingga Grafana bisa akses Prometheus lewat:

```text
http://prometheus:9090
```

## Operasional

Semua operasional project ini memakai shell script utama:

```bash
cd db-port-monitoring
./promeblackbox.sh validate
./promeblackbox.sh start
./promeblackbox.sh status
```

Command lain:

```bash
./promeblackbox.sh stop
./promeblackbox.sh restart
./promeblackbox.sh logs
./promeblackbox.sh reload
./promeblackbox.sh targets
./promeblackbox.sh probe db-postgres.example.com:5432
./promeblackbox.sh query
./promeblackbox.sh writer-query
```

`blackbox-pg-writer` mengambil raw sample Prometheus dalam range waktu yang overlap, lalu menyimpannya ke PostgreSQL existing memakai env dari `.env` di project ini. Overlap membuat sample yang terlambat, termasuk probe timeout, tetap terambil; unique key `(checked_at, target_name)` mencegah duplikasi. Jika writer sempat berhenti, proses backfill dilanjutkan per chunk sampai mengejar waktu sekarang.

Schema migration/backfill dijalankan manual saat ada perubahan SQL:

```bash
./promeblackbox.sh build-writer
./promeblackbox.sh pg-schema
./promeblackbox.sh writer-start
./promeblackbox.sh reload
```

File `.env` berisi credential dan harus memakai permission `600`.
Koneksi PostgreSQL memakai `PGCONNECT_TIMEOUT=10` agar kegagalan jaringan cepat masuk ke health metric dan alert writer.

## Target Monitoring

Target berada di:

```text
prometheus/targets/db-targets.yml
```

File ini menjadi source of truth target Prometheus Blackbox.
File tersebut sengaja tidak disimpan di Git karena dapat berisi hostname dan IP
produksi. Buat file lokal dari template sebelum menjalankan service:

```bash
cp prometheus/targets/db-targets.example.yml prometheus/targets/db-targets.yml
```

Label standar per target:

- `db_name`
- `db_type`
- `env`
- `team`
- `criticality`

Untuk tambah target, edit `prometheus/targets/db-targets.yml`, lalu reload Prometheus:

```bash
./promeblackbox.sh reload
```

Jika reload gagal karena Prometheus belum running, jalankan:

```bash
./promeblackbox.sh restart
```

## Grafana Datasource

Tambahkan datasource baru di Grafana:

- Type: `Prometheus`
- URL: `http://prometheus:9090`
- UID: `grafana-prometheus-datasource`

File referensi provisioning ada di:

```text
grafana/provisioning/datasources/prometheus-datasource.yml
```

## Grafana Dashboard

Import dashboard JSON berikut:

- `grafana/db-port-availability-overview-prometheus.json`
- `grafana/db-port-target-detail-prometheus.json`
- `grafana/db-port-availability-overview-sql.json`
- `grafana/db-port-target-detail-sql.json`
- `grafana/db-port-blackbox-sql-ingest-verification.json`

Dashboard overview berisi ringkasan global, DOWN by env/db type, latency group, dan tabel status target.

Dashboard target detail berisi satu target per view, timeline UP/DOWN, latency, status change, dan down samples pada selected range.

Dashboard SQL availability membaca data dari PostgreSQL untuk kebutuhan KPI dan reporting jangka panjang. Panel real-time memakai raw probe data 30 hari, sedangkan panel YTD/monthly memakai aggregate harian 400 hari.

Dashboard SQL juga memakai tabel summary-detail jangka panjang untuk tetap bisa menjawab kapan target down tanpa menyimpan raw 10 detik selama ratusan hari:

- `monitoring.db_port_blackbox_hourly_kpi`
- `monitoring.db_port_blackbox_status_events`
- `monitoring.db_port_blackbox_downtime_events`
- `monitoring.db_port_blackbox_latency_events`
- `monitoring.db_port_blackbox_daily_error_summary`

Dashboard SQL ingest verification dipakai untuk memastikan stream Prometheus sudah masuk PostgreSQL tanpa target missing, ingest lag tinggi, backlog backfill, writer failure, atau drift antara raw data dan aggregate KPI.

## PromQL Utama

```promql
probe_success{job="db-port-availability"}
probe_duration_seconds{job="db-port-availability"}
```

Status:

- `probe_success = 1`: target UP / reachable
- `probe_success = 0`: target DOWN / timeout / refused / unreachable

## Alert Rules

Rule Prometheus tersedia di:

```text
prometheus/alert-rules.yml
```

Rule:

- `DBPortDown`: `probe_success == 0 for 3m`
- `DBPortProbeSlow`: successful probe dengan latency lebih dari 3 detik selama 5 menit
- `DBPortProbeScrapeFailed`: Prometheus gagal scrape target selama 1 menit
- `DBPortMetricsMissing`: seluruh metric probe hilang
- `BlackboxPGWriterDown`: endpoint health writer tidak dapat di-scrape
- `BlackboxPGWriterCycleFailed`: siklus insert PostgreSQL gagal
- `BlackboxPGWriterIngestStale`: tidak ada ingest sukses selama lebih dari 60 detik
- `BlackboxPGWriterBackfillBehind`: backlog writer lebih dari 5 menit

Rule Prometheus sudah mendeteksi kondisi tersebut. Pengiriman notifikasi ke email, Slack, atau webhook tetap membutuhkan receiver Alertmanager yang sesuai dengan channel operasional perusahaan.

## Retention

Prometheus retention:

```text
15d
2GB hard cap
```

Prometheus akan memangkas data yang lebih tua dari 15 hari, atau lebih cepat jika storage TSDB mencapai 2GB. Dengan target saat ini, ini dibuat supaya data monitoring tidak membengkak dan membebani server.

Data TSDB Prometheus disimpan di folder project:

```text
data/prometheus
```

PostgreSQL retention:

```text
Raw probe data: 30d
Hourly/Daily KPI and events: 400d
```

Raw Blackbox probe data disimpan di:

```text
monitoring.db_port_blackbox_probe_results
```

Daily KPI aggregate disimpan di:

```text
monitoring.db_port_blackbox_daily_kpi
```

Downtime/status/latency event history disimpan di:

```text
monitoring.db_port_blackbox_downtime_events
monitoring.db_port_blackbox_status_events
monitoring.db_port_blackbox_latency_events
```

View reporting:

```text
monitoring.db_port_blackbox_hourly_availability
monitoring.db_port_blackbox_daily_availability
monitoring.db_port_blackbox_monthly_availability
monitoring.db_port_blackbox_yearly_availability
monitoring.db_port_blackbox_downtime_event_history
monitoring.db_port_blackbox_latency_event_history
```

Writer berjalan setiap 10 detik, menghapus raw row yang lebih tua dari `BLACKBOX_RAW_RETENTION_DAYS`, dan mempertahankan KPI/event summary sesuai `BLACKBOX_KPI_RETENTION_DAYS`.

Pengaturan recovery writer:

```text
PROMETHEUS_QUERY_OVERLAP_SECONDS=60
PROMETHEUS_BACKFILL_CHUNK_SECONDS=3600
PROMETHEUS_INITIAL_BACKFILL_SECONDS=3600
PROMETHEUS_MAX_BACKFILL_SECONDS=1296000
PROMETHEUS_MAX_BACKFILL_CHUNKS_PER_CYCLE=6
BLACKBOX_TARGET_INACTIVE_AFTER_SECONDS=86400
```

Nilai default memungkinkan backfill dari retention Prometheus 15 hari, diproses maksimal enam chunk per siklus agar PostgreSQL tidak menerima satu batch yang terlalu besar.
