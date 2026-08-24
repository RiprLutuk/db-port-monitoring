# Prometheus + Blackbox Exporter DB Port Monitoring

Project ini memonitor availability port database dengan TCP probe:

- Blackbox Exporter melakukan connect ke `host:port`.
- Prometheus scrape hasil probe setiap 5 menit.
- Writer menyimpan hasil ke PostgreSQL; Grafana membaca status dan KPI dari sana.
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
./promeblackbox.sh verify
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

Jika satu window Prometheus benar-benar tidak memiliki sample, writer mencatat warning
dan melanjutkan ke window berikutnya. Tidak ada row UP/DOWN sintetis yang dibuat untuk
gap tersebut, sehingga recovery tidak macet dan histori tetap merepresentasikan data
yang benar-benar tersedia. Cursor source disimpan secara durable di
`monitoring.db_port_blackbox_writer_state`, sehingga restart tidak mengulang dan
terkunci lagi pada window kosong yang sama.

Setelah start, restart, atau perubahan target, jalankan pemeriksaan end-to-end:

```bash
./promeblackbox.sh verify
```

Command ini gagal dengan exit non-zero jika target Prometheus dan PostgreSQL tidak
sama, ada target tanpa sample recent, data/checkpoint stale, KPI counter tidak valid,
downtime event overlap, future row, backlog, atau writer health bermasalah.

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
- `monitoring_excluded` (opsional, `true` untuk dikecualikan dari dashboard KPI utama)

Target dengan `monitoring_excluded: "true"` tetap di-scrape dan tetap masuk raw serta
daily KPI PostgreSQL. Flag ini hanya mengecualikan target dari perhitungan dan tampilan
dashboard KPI utama serta alert per-target. Exclusion aktif saat ini: `bmgcp-011-qa`,
`bmjkt-000197`, dan `db-interval-qas`.

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

Dashboard detail historical per server tersedia sebagai dashboard baru dan di-import
terpisah tanpa mengganti dashboard KPI:

```text
grafana/db-port-availability-details.json
```

Dashboard detail menggunakan `db_port_blackbox_daily_kpi` untuk KPI dan summary
harian sesuai time picker atau bulan yang dipilih. Tabel downtime membaca
`db_port_blackbox_downtime_events`: satu row per insiden berisi waktu mulai, waktu
pulih, durasi, dan jumlah failed sample. Event dan summary harian disimpan selama
retention report. Event Prometheus lama direkonstruksi dari raw yang masih tersedia
saat migration. Backfill OpManager memakai timestamp exact dari `DownTime*`,
`ParentDown*`, dan `DependentUnavailable*`, sedangkan daily counter-nya masuk langsung
ke daily KPI. Detail audit dan query ada di
`docs/OPMANAGER-HISTORICAL-BACKFILL.md`. Refresh dashboard mengikuti cadence ingest
5 menit. Dashboard historical tetap menampilkan target `monitoring_excluded=true`;
exclusion hanya berlaku pada dashboard KPI utama.
Gap event pada daily KPI existing yang raw probe-nya sudah terhapus diisi satu kali
oleh `sql/009_backfill_estimated_downtime_events.sql`. Event tersebut selalu diberi
source `daily-kpi-estimated-00-03` dan label `estimated`; jam 00:00 adalah asumsi,
bukan timestamp probe asli.
Kartu KPI memakai Canvas Grafana untuk menampilkan nilai dan keterangan ringkas;
jumlah hari mengikuti bulan/range yang dipilih dan downtime ditampilkan sebagai
durasi `d/h/m`. Progress bar memakai ulang hasil query kartu melalui datasource
Dashboard Grafana, sehingga tidak menambah query PostgreSQL.

File dashboard Prometheus/SQL lain yang masih ada di folder `grafana/` dipertahankan
sebagai arsip/referensi dan tidak termasuk jalur operasional KPI. File tersebut dapat
merujuk objek legacy yang sudah dihapus dari PostgreSQL.

Status terbaru dibaca dari `monitoring.probe_current_status` melalui indexed lookup
per target. KPI historis membaca `monitoring.db_port_blackbox_daily_kpi`, dan detail
insiden membaca `monitoring.db_port_blackbox_downtime_events`. View kompatibilitas
lain tetap tersedia tetapi bukan dependency dashboard aktif dan tidak menyimpan
salinan data.

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
- `BlackboxPGWriterProbeDataStale`: sample PostgreSQL lebih tua dari 15 menit
- `BlackboxPGWriterTargetsMissing`: target aktif tidak punya sample recent
- `BlackboxPGWriterSourceGap`: source window Prometheus kosong
- `BlackboxPGWriterCycleSlow`: durasi cycle mendekati interval 5 menit
- `BlackboxPGRawRetentionBehind`: cleanup raw melewati retention dan grace period
- `BlackboxPGRawTableLarge`: raw table dan index melebihi 2 GiB
- `BlackboxPGDailyKPIMissing`: target dashboard tidak punya KPI hari kemarin
- `BlackboxPGDailyKPIPartial`: KPI hari kemarin tidak berisi 288 probe
- `AlertmanagerDown`: Prometheus tidak dapat mengakses Alertmanager
- `AlertmanagerTelegramDeliveryFailed`: pengiriman Telegram gagal

Alertmanager aktif sebagai service terpisah dan mengirim FIRING/RESOLVED ke Telegram.
`DBPortDown` mulai firing setelah 10 menit gagal dan diulang tiap 15 menit selama
masih DOWN. Critical lain diulang tiap 1 jam, sedangkan alert non-critical tiap 4
jam. Credential hanya disimpan di `.env` lokal dan dipasang ke container melalui
`/run/secrets`; nilainya tidak disimpan dalam file konfigurasi atau Git.

Konfigurasi receiver tersedia di:

```text
alertmanager/alertmanager.yml
```

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
Downtime events: 2192d (sekitar 6 tahun)
```

Raw Blackbox probe data disimpan di:

```text
monitoring.db_port_blackbox_probe_results
```

Daily KPI aggregate disimpan di:

```text
monitoring.db_port_blackbox_daily_kpi
```

Waktu mulai/pulih setiap insiden disimpan di:

```text
monitoring.db_port_blackbox_downtime_events
```

View yang dipakai dashboard:

```text
monitoring.probe_current_status
```

Writer berjalan setiap 5 menit dan menerapkan retention bertingkat:

```text
BLACKBOX_RAW_RETENTION_DAYS=30
BLACKBOX_REPORT_RETENTION_DAYS=2192
BLACKBOX_RETENTION_DELETE_BATCH_SIZE=10000
```

Daily KPI hanya menghasilkan satu row per target per hari. Untuk `N` target, raw
cadence 5 menit menghasilkan sekitar `N x 288` row per hari, sedangkan daily KPI
hanya `N` row per hari. Empat tabel storage aktif adalah inventory target, raw probe,
daily KPI, dan compact downtime events. Tidak ada lagi tabel hourly, latency event,
error summary, status event, atau backup `pre_1m` yang ditulis oleh writer.

Retention memakai indexed, bounded delete maksimal 10.000 row per tabel per ingest
window. Ini mencegah transaksi cleanup besar setelah writer lama berhenti. Raw table
dan index dipantau melalui metric `blackbox_pg_writer_raw_table_bytes`; alert aktif
jika ukuran melewati 2 GiB, retention tertinggal lebih dari satu jam, atau durasi
cycle memakai lebih dari 80% interval. Autovacuum raw juga dituning melalui
`sql/012_storage_scalability_guards.sql` agar dead tuple dari rolling retention tidak
menumpuk.

Histori existing sudah dinormalisasi melalui
`sql/006_normalize_history_to_five_minutes.sql`. Setelah normalisasi tidak ada lebih
dari satu raw row untuk target yang sama dalam bucket 5 menit, dan KPI harian dibangun
ulang dari bucket tersebut. Migration ini bersifat one-time dan sekarang menolak
berjalan bila downtime events sudah berisi data agar histori insiden tidak menjadi
tidak sinkron.

Khusus gangguan host monitoring pada `2026-08-22`, daily KPI dilengkapi sampai 288
sampel melalui `sql/010_backfill_2026_08_22_monitoring_gap.sql`. Sampel yang hilang
dianggap UP berdasarkan `2026-08-21` yang lengkap dan seluruh targetnya UP.
Gangguan lanjutan pada `2026-08-23` ditangani terpisah oleh
`sql/011_backfill_2026_08_23_monitoring_gap.sql`: seluruh 84 row sumber memiliki
224-227 probe dan nol observed DOWN. Migration memasukkan row raw UP berlabel untuk
setiap bucket lima menit yang kosong, lalu membangun ulang daily KPI dari 288 bucket
unik per target. Koreksi tanggal 22 hanya mengubah aggregate; koreksi tanggal 23
menyimpan asumsi sampai raw dengan `source=monitoring-gap-assumed-up-2026-08-23`.

Retention baru hanya menjaga data sejak data tersebut mulai dikumpulkan. Data yang sudah tidak tersedia di PostgreSQL, Prometheus, atau backup tidak dapat dibuat ulang; karena itu panel YoY akan kosong sampai periode pembanding tahun sebelumnya benar-benar tersedia.

Pengaturan recovery writer:

```text
PROMETHEUS_QUERY_OVERLAP_SECONDS=180
PROMETHEUS_BACKFILL_CHUNK_SECONDS=3600
PROMETHEUS_INITIAL_BACKFILL_SECONDS=3600
PROMETHEUS_MAX_BACKFILL_SECONDS=1296000
PROMETHEUS_MAX_BACKFILL_CHUNKS_PER_CYCLE=6
BLACKBOX_TARGET_INACTIVE_AFTER_SECONDS=86400
BLACKBOX_RETENTION_DELETE_BATCH_SIZE=10000
WRITER_STATE_NAME=prometheus-blackbox
BLACKBOX_DATA_FRESHNESS_SECONDS=900
BLACKBOX_RAW_TABLE_MAX_BYTES=2147483648
BLACKBOX_RETENTION_GRACE_SECONDS=3600
BLACKBOX_WRITER_CYCLE_MAX_SECONDS=240
```

Nilai default memungkinkan backfill dari retention Prometheus 15 hari, diproses maksimal enam chunk per siklus agar PostgreSQL tidak menerima satu batch yang terlalu besar.

Checkpoint source adalah state operasional kecil dan tidak terkena retention raw.
Ingest PostgreSQL bersifat idempotent: raw memakai unique key
`(checked_at, target_name)`, sedangkan KPI dan downtime event hanya menerima row raw
yang benar-benar baru di dalam transaksi yang sama.

Jika Prometheus masih mempunyai sample, writer dapat mengejar gangguan sampai batas
retention Prometheus. Jika host monitoring berhenti melakukan scrape, sample pada
periode itu memang tidak pernah tercipta dan tidak boleh direkonstruksi sebagai UP
atau DOWN. Runbook diagnosis dan recovery ada di
`docs/BLACKBOX-PIPELINE-RUNBOOK.md`.

Untuk menerapkan cadence 5 menit tidak perlu rebuild image. Validasi konfigurasi,
reload Prometheus, lalu recreate writer agar environment baru terbaca:

```bash
./promeblackbox.sh validate
./promeblackbox.sh reload
./promeblackbox.sh writer-start
```

Storage PostgreSQL yang aktif mempertahankan raw probe 30 hari serta daily KPI dan
downtime events sekitar enam tahun. Tabel legacy lain sudah di-drop melalui migration
`sql/005_kpi_only_cleanup.sql`.
