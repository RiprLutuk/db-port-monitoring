# Prometheus + Blackbox Exporter DB Port Monitoring

Project ini memonitor availability port database dengan TCP probe:

- Blackbox Exporter melakukan connect ke `host:port`.
- Prometheus scrape hasil probe setiap 5 menit.
- Grafana membaca metric dari Prometheus.
- Tidak ada credential database target yang disimpan atau dipakai.

Panduan sistem dan jawaban singkat untuk meeting tersedia di
`docs/DB-PORT-MONITORING-FAQ.md`.

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
cd promeblackbox
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
./promeblackbox.sh normalize-environment
./promeblackbox.sh writer-start
./promeblackbox.sh reload
```

`normalize-environment` hanya mengubah nilai dimension `environment` lama dari
`qa`/`uat` menjadi `dev`; nama target dan `db_name` tidak diubah. Writer juga
menormalisasi metric baru sebelum insert sebagai pengaman.

Histori yang pernah dikumpulkan dengan cadence 10 detik atau 1 menit dinormalisasi
satu kali menjadi satu observasi per target per bucket 5 menit:

```bash
./promeblackbox.sh build-writer
./promeblackbox.sh writer-stop
./promeblackbox.sh normalize-5m
./promeblackbox.sh writer-start
```

Migration menolak berjalan bila writer masih aktif. Jika satu bucket memiliki probe
UP dan DOWN, bucket disimpan sebagai DOWN agar kegagalan lama tidak hilang.

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
- `monitoring_excluded` (opsional, `true` untuk tidak dihitung/ditampilkan)

Target dengan `monitoring_excluded: "true"` tetap di-scrape dan tetap masuk raw serta
daily KPI PostgreSQL. Flag ini hanya mengecualikan target dari perhitungan KPI,
tampilan/variable dashboard, dan alert per-target. Exclusion aktif saat ini:
`bmgcp-011-qa` dan `bmjkt-000197`.

Untuk tambah target, edit `prometheus/targets/db-targets.yml`. Folder target di-bind
mount dan Prometheus file discovery refresh setiap 60 detik, sehingga perubahan
target tidak memerlukan rebuild image atau restart container. Tunggu sekitar 1-2
menit, lalu cek:

```bash
./promeblackbox.sh targets
```

`./promeblackbox.sh reload` terutama diperlukan jika mengubah `prometheus.yml` atau
alert rules, bukan untuk perubahan target biasa.

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

Dashboard aktif yang dipakai adalah:

```text
grafana/db-port-kpi-executive-reporting-sql.json
```

Dashboard ini memiliki tujuh panel ringkas: total target, port UP, port DOWN, current
availability, KPI availability sesuai time picker, enam target dengan availability
terendah, dan card status port terbaru. Card status hanya menampilkan UP/DOWN.
Target berlabel `monitoring_excluded=true` tidak ikut seluruh panel dan filter tersebut.

File dashboard Prometheus/SQL lain yang masih ada di folder `grafana/` dipertahankan
sebagai arsip/referensi dan tidak termasuk jalur operasional KPI. File tersebut dapat
merujuk objek legacy yang sudah dihapus dari PostgreSQL.

Status terbaru dibaca dari `monitoring.probe_current_status` melalui indexed lookup
per target. KPI historis membaca `monitoring.db_port_blackbox_daily_kpi` berdasarkan
rentang waktu Grafana. View kompatibilitas `monitoring.probe_history` dan
`monitoring.probe_availability_30d` tetap tersedia, tidak menyimpan salinan data, dan
tidak menggantikan tabel retention internal.

Pada dashboard KPI, pilihan Environment disederhanakan menjadi `dev` dan `prod`.
`qa`, `uat`, dan `development` dinormalisasi menjadi `dev` di konfigurasi/ingest,
dan histori lama di PostgreSQL sudah dimigrasikan. Nama database boleh tetap
mengandung teks `qa` atau `uat`; yang menentukan filter adalah label `environment`.

Availability pada dashboard adalah gross technical availability dari TCP probe. Planned maintenance belum dikecualikan karena project belum memiliki sumber maintenance window yang authoritative; angka ini tidak boleh disebut contractual SLA sebelum aturan maintenance dan business exclusion disepakati.

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

- `DBPortDown`: `probe_success == 0 for 10m`
- `DBPortProbeSlow`: successful probe dengan latency lebih dari 3 detik selama 10 menit
- `DBPortProbeScrapeFailed`: Prometheus gagal scrape target selama 10 menit
- `DBPortMetricsMissing`: seluruh metric probe hilang selama lebih dari 10 menit
- `BlackboxPGWriterDown`: endpoint health writer tidak dapat di-scrape
- `BlackboxPGWriterCycleFailed`: siklus insert PostgreSQL gagal
- `BlackboxPGWriterIngestStale`: tidak ada ingest sukses selama lebih dari 600 detik
- `BlackboxPGWriterBackfillBehind`: backlog writer lebih dari 10 menit

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
Daily KPI: 2192d (sekitar 6 tahun)
```

Raw Blackbox probe data disimpan di:

```text
monitoring.db_port_blackbox_probe_results
```

Daily KPI aggregate disimpan di:

```text
monitoring.db_port_blackbox_daily_kpi
```

View yang dipakai dashboard:

```text
monitoring.db_port_blackbox_daily_availability
monitoring.db_port_blackbox_monthly_availability
monitoring.db_port_blackbox_yearly_availability
monitoring.probe_current_status
monitoring.probe_availability_30d
```

Writer berjalan setiap 5 menit dan menerapkan retention bertingkat:

```text
BLACKBOX_RAW_RETENTION_DAYS=30
BLACKBOX_REPORT_RETENTION_DAYS=2192
```

Daily KPI hanya menghasilkan satu row per target per hari. Untuk `N` target, raw
cadence 5 menit menghasilkan sekitar `N x 288` row per hari, sedangkan daily KPI
hanya `N` row per hari. Tiga tabel inti yang aktif adalah inventory target, raw probe,
dan daily KPI. Tidak ada lagi tabel hourly, event, error summary, atau backup
`pre_1m` yang ditulis oleh writer.

Histori existing sudah dinormalisasi melalui
`sql/006_normalize_history_to_five_minutes.sql`. Setelah normalisasi tidak ada lebih
dari satu raw row untuk target yang sama dalam bucket 5 menit, dan KPI harian dibangun
ulang dari bucket tersebut.

Retention baru hanya menjaga data sejak data tersebut mulai dikumpulkan. Data yang sudah tidak tersedia di PostgreSQL, Prometheus, atau backup tidak dapat dibuat ulang; karena itu panel YoY akan kosong sampai periode pembanding tahun sebelumnya benar-benar tersedia.

Pengaturan recovery writer:

```text
PROMETHEUS_QUERY_OVERLAP_SECONDS=180
PROMETHEUS_BACKFILL_CHUNK_SECONDS=3600
PROMETHEUS_INITIAL_BACKFILL_SECONDS=3600
PROMETHEUS_MAX_BACKFILL_SECONDS=1296000
PROMETHEUS_MAX_BACKFILL_CHUNKS_PER_CYCLE=6
BLACKBOX_TARGET_INACTIVE_AFTER_SECONDS=86400
```

Nilai default memungkinkan backfill dari retention Prometheus 15 hari, diproses maksimal enam chunk per siklus agar PostgreSQL tidak menerima satu batch yang terlalu besar.

Untuk menerapkan cadence 5 menit tidak perlu rebuild image. Validasi konfigurasi,
reload Prometheus, lalu recreate writer agar environment baru terbaca:

```bash
./promeblackbox.sh validate
./promeblackbox.sh reload
./promeblackbox.sh writer-start
```

Storage PostgreSQL yang aktif hanya mempertahankan raw probe 30 hari dan daily KPI
untuk kebutuhan dashboard ini. Tabel legacy sudah di-drop melalui migration
`sql/005_kpi_only_cleanup.sql`.
