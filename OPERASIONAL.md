# Panduan Operasional Promeblackbox

Panduan singkat untuk konfigurasi project saat ini. Jalankan perintah dari folder
project, menggunakan akun yang memiliki akses Docker.

## 1. Cara kerja

`Target host:port → Blackbox Exporter → Prometheus → Writer → PostgreSQL → Grafana`

- Probe TCP dan penyimpanan hasil berjalan setiap **5 menit**.
- Empat service dalam project: `alertmanager`, `prometheus`, `blackbox-exporter`, dan `blackbox-pg-writer`.
- PostgreSQL penyimpan hasil dan Grafana berada di luar Compose project ini.
- Alert Prometheus diteruskan ke Alertmanager untuk Telegram/email sesuai konfigurasi lokal. Grafana juga memiliki rule tersendiri.
- **UP berarti port dapat dihubungi**, bukan jaminan login/query database berhasil. Probe TCP tidak memakai credential database target.

## 2. Pemeriksaan harian

```bash
cd /dataplatform/data-tools/promeblackbox
./promeblackbox.sh status
./promeblackbox.sh verify
```

Kondisi normal: empat container berjalan dan healthy, lalu `verify` menampilkan
`All blackbox pipeline checks passed.` Pemeriksaan ini mencakup koneksi service,
kesegaran data, jumlah target, checkpoint/backlog writer, integritas KPI/event,
retention, serta kelengkapan KPI kemarin. Target yang benar-benar DOWN tetap dapat
lolos verifikasi pipeline apabila hasil DOWN berhasil dikumpulkan dan disimpan.

Buka dashboard Grafana:

| Dashboard / file sumber | Kegunaan |
| --- | --- |
| `grafana/db-port-kpi-executive-reporting-sql.json` | Status terbaru dan KPI availability |
| `grafana/db-port-availability-details.json` | Histori per server, KPI harian, dan insiden downtime |

Periksa rentang waktu dan environment (`dev`/`prod`). Sesudah start atau perubahan,
beri waktu sekitar **5–10 menit** untuk scrape dan ingest; recovery backlog bisa
lebih lama. Data stale tidak boleh dianggap sebagai status UP terbaru.

## 3. Perintah utama

```bash
./promeblackbox.sh start                 # Menyalakan / menerapkan perubahan Compose
./promeblackbox.sh stop                  # Menghentikan empat service
./promeblackbox.sh restart               # Restart empat service
./promeblackbox.sh logs                  # Semua log; Ctrl+C untuk keluar
./promeblackbox.sh logs alertmanager     # Log service tertentu
./promeblackbox.sh writer-logs           # Log ingest PostgreSQL
./promeblackbox.sh targets               # Daftar target aktif Prometheus (JSON)
./promeblackbox.sh query                 # Hasil probe_success (JSON)
./promeblackbox.sh writer-query          # Jumlah raw row dan waktu data pertama/terakhir
./promeblackbox.sh probe db-postgres.example.com:5432
```

Ganti host contoh dengan target yang ingin diperiksa. Hasil `probe_success 1`
berarti reachable; `0` berarti gagal connect/timeout/refused. Perintah `probe`
hanya mengetes satu kali dan tidak menulis hasil ke histori.

## 4. Tambah, ubah, atau hapus target

Edit `prometheus/targets/db-targets.yml`; contoh satu target:

```yaml
- targets:
    - "db-postgres.example.com:5432"
  labels:
    db_name: "example-postgres"
    db_type: "postgresql"
    env: "dev"
    team: "platform"
    criticality: "medium"
```

1. Salin file target sebagai backup sebelum mengedit. Gunakan environment `dev` atau `prod`.
2. Jalankan `./promeblackbox.sh validate`.
3. Discovery membaca perubahan tiap 60 detik; cek dengan `./promeblackbox.sh targets` setelah 1–2 menit. Tidak perlu restart atau rebuild.
4. Tunggu scrape/ingest berikutnya, kemudian jalankan `./promeblackbox.sh verify`.

Untuk menghapus target, hapus entry terkait. Inventory PostgreSQL default baru
menandainya inactive setelah **24 jam** tidak terlihat; selisih jumlah target pada
`verify` dapat terjadi selama transisi ini. Histori mengikuti retention.

Label opsional `monitoring_excluded: "true"` mengecualikan target dari dashboard
KPI utama dan alert per-target. Raw/KPI tetap disimpan dan dashboard historical
tetap menampilkannya.

## 5. Mengubah konfigurasi / memperbarui project

| Yang berubah | Cara menerapkan |
| --- | --- |
| `prometheus.yml`, `alert-rules.yml`, atau routing `alertmanager.yml` | `./promeblackbox.sh validate` lalu `./promeblackbox.sh reload` (reload keduanya) |
| `.env` untuk writer | `./promeblackbox.sh writer-start` (recreate writer) |
| `.env` token/chat Telegram | `docker compose up -d --force-recreate alertmanager`, lalu cek status/log Alertmanager |
| `docker-compose.yml` | `./promeblackbox.sh start`, lalu cek status/log service terkait |
| Script writer / SQL yang masuk image | `./promeblackbox.sh build-writer`, migration yang diperlukan sesuai perubahan, lalu `./promeblackbox.sh writer-start` |
| `blackbox/blackbox.yml` | `docker compose restart blackbox-exporter`, lalu tes `probe` |

`restart` biasa tidak membaca ulang environment container. Setelah perubahan,
cek `status`, log service terkait, lalu `verify`. Migration SQL dijalankan manual;
perintah normalisasi histori dan `cleanup-unused` bukan kegiatan rutin.

Untuk alert Grafana yang memakai generator/inventory deployment lokal:

```bash
./promeblackbox.sh deploy-grafana-alerts --dry-run
./promeblackbox.sh deploy-grafana-alerts
```

Perlu `GRAFANA_PROJECT_DIR`, generator lokal, Python/PyYAML, dan akses `sudo`.
Dry-run tetap menghasilkan file staging, tetapi tidak mengubah Grafana. Deploy
hanya menyalin file yang berubah dan restart Grafana; timer `for` alert dimulai ulang.

Jika autodiscovery telah dikonfigurasi, sinkronisasi manual memakai
`./promeblackbox.sh auto-sync-grafana-alerts`. Timer berjalan tiap sekitar 15 menit:

```bash
systemctl list-timers promeblackbox-alert-autodiscovery.timer
journalctl -u promeblackbox-alert-autodiscovery.service -n 100 --no-pager
```

## 6. Penanganan masalah

| Gejala | Langkah awal |
| --- | --- |
| Target DOWN | Jalankan `probe host:port`; cek database/listener, DNS, firewall/security group, dan jalur jaringan dari host/container monitoring. `DBPortDown` memakai kondisi gagal selama 10 menit. |
| Banyak target hilang / scrape gagal | Cek `status`, `targets`, log Prometheus dan Blackbox Exporter, lalu validasi YAML target. |
| Grafana tidak berubah / data stale | Cek rentang waktu, `writer-logs`, `writer-query`, dan `verify`; periksa koneksi/credential PostgreSQL serta disk. Setelah penyebab beres: `writer-start`, tunggu catch-up, lalu `verify` lagi. |
| Container berhenti / unhealthy | Baca log service, perbaiki penyebab, jalankan `start`, lalu `status` dan `verify`. |
| Alert tidak terkirim | Cek alert firing di Prometheus/Grafana, readiness dan log Alertmanager, routing/receiver, secret Telegram, serta akses SMTP/jaringan. `verify` bukan tes pengiriman notifikasi. |
| `verify` gagal setelah perubahan target | Lihat baris `FAIL`; bedakan masa tunggu ingest/inactive inventory dari masalah koneksi atau data. Jangan mengabaikan kegagalan yang menetap. |

Endpoint UI hanya tersedia di localhost server:

- Prometheus: `http://127.0.0.1:9090` (alert: `/alerts`, target: `/targets`).
- Blackbox Exporter: `http://127.0.0.1:9115`.
- Alertmanager: `http://127.0.0.1:9093`.

Grafana mengakses Prometheus melalui network Docker di `http://prometheus:9090`.

## 7. Data, recovery, dan backup

- Prometheus: **15 hari atau batas 2 GB**, tersimpan di `data/prometheus`.
- PostgreSQL: raw **30 hari**; daily KPI dan downtime events **2192 hari** (sekitar 6 tahun).
- Writer melanjutkan checkpoint dan backfill otomatis dari sampel Prometheus yang masih tersedia, default maksimal 15 hari. Jangan reset checkpoint untuk recovery biasa.
- Jika host monitoring tidak melakukan scrape, sampel periode tersebut memang tidak ada; jangan mengisi gap sebagai UP/DOWN tanpa bukti.
- Backup PostgreSQL mencakup schema monitoring beserta data/checkpoint. Simpan juga `.env`, target, routing Alertmanager, dan konfigurasi Grafana lokal secara aman. Backup Prometheus diperlukan bila ingin mempertahankan sumber raw untuk backfill; gunakan snapshot/backup yang konsisten.
- `stop` tidak menghapus data. Jangan menghapus `data/` atau menjalankan `docker compose down -v` untuk troubleshooting biasa.
- Availability adalah hasil teknis TCP probe; planned maintenance belum dikecualikan dan angka ini belum merupakan SLA kontraktual.

## 8. Setup di host baru (sekali saja)

Siapkan Docker Engine + Compose v2 yang mendukung `env_file.format: raw`, Bash,
`curl`, dan `jq`. PostgreSQL harus dapat dijangkau dari container dan Grafana
disiapkan terpisah. Pastikan network `grafana_default` tersedia dari project
Grafana; jika belum ada, buat dengan `docker network create grafana_default`.

```bash
# Hanya jika file lokal belum ada; jangan menimpa konfigurasi deployment existing.
cp .env.example .env
chmod 600 .env
cp prometheus/targets/db-targets.example.yml prometheus/targets/db-targets.yml
cp alertmanager/alertmanager.example.yml alertmanager/alertmanager.yml
```

Isi koneksi PostgreSQL (`PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`),
token/chat Telegram, target, dan routing SMTP/receiver sesuai environment. User
PostgreSQL perlu hak untuk membuat/memperbarui objek schema saat migration.
Untuk PostgreSQL pada host Docker, pastikan listener dan `pg_hba.conf` menerima
koneksi dari jaringan container.

Siapkan `data/prometheus` agar dapat ditulis user container Prometheus. Image saat
ini memakai user `nobody`; pastikan ownership/permission folder sesuai UID/GID
user tersebut di image, terutama jika folder dibuat oleh root. Kesalahan izin
akan terlihat sebagai `permission denied` pada log Prometheus.

```bash
./promeblackbox.sh build-writer
./promeblackbox.sh validate
./promeblackbox.sh pg-schema
./promeblackbox.sh start
# Setelah tersedia sampel dan ingest:
./promeblackbox.sh status
./promeblackbox.sh verify
```

Pada instalasi baru, cek kelengkapan KPI kemarin dapat gagal karena belum ada
histori sehari penuh. Import/provision dashboard dan datasource Grafana secara
terpisah sesuai [README](README.md). Kedua dashboard aktif memakai **datasource
PostgreSQL** dengan UID `grafana-postgresql-datasource`, yang harus menunjuk ke
database penyimpan schema `monitoring` dan memiliki hak baca. Datasource
Prometheus (`grafana-prometheus-datasource`) digunakan untuk query metrik;
menambah datasource Prometheus saja belum cukup untuk dashboard SQL.
Jangan commit `.env`, inventory target,
atau konfigurasi deployment yang berisi informasi internal.
