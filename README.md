# Sinkronisasi Presensi Otomatis (Simpegnas BKN)

Repositori ini berisi kumpulan skrip `bash` yang dirancang untuk mengotomatisasi proses sinkronisasi data presensi (kehadiran) pegawai dari **API Simpegnas BKN**. Skrip ini akan mengambil data secara terjadwal, menyimpannya ke database MySQL lokal, melakukan proses ETL (Extract, Transform, Load), dan mengirimkan laporan status melalui Telegram.

## ✨ Fitur Utama

* **Sinkronisasi Otomatis**: Mengambil data rekap presensi harian per kantor dari API Simpegnas BKN.
* **Penjadwalan Cerdas**: Menjalankan skrip yang berbeda berdasarkan waktu (sinkronisasi massal di pagi hari, sinkronisasi per kantor di jam kerja).
* **Proses ETL**: Melakukan proses Extract, Transform, Load untuk memindahkan data dari tabel sementara (`presensi`) ke tabel arsip (`tb_scanlog_ars`).
* **Notifikasi Telegram**: Memberikan laporan ringkas setelah setiap operasi berhasil, termasuk statistik panggilan API.
* **Penghindaran Duplikasi**: Memastikan data yang sama tidak dimasukkan berulang kali baik di tabel `presensi` maupun `tb_scanlog_ars`.
* **Manajemen Status**: Menggunakan *flag* dan *lock file* untuk mencegah eksekusi ganda dan menandai data yang sudah diproses.

---

## ⚙️ Arsitektur & Alur Kerja

Sistem ini terdiri dari empat skrip utama yang bekerja sama dan diatur oleh satu `cron job`.

1.  **Pemicu (`cron`)**: Sebuah `cron job` diatur untuk menjalankan skrip utama `cron_dispatcher.sh` secara berkala (misalnya, setiap 10 menit).

2.  **Pemandu (`cron_dispatcher.sh`)**: Skrip ini memeriksa jam saat ini:
    * **Jika sebelum jam 09:00**: Ia menjalankan `sync_presensi_range.sh 7` untuk mengambil data historis 7 hari terakhir. Ini berguna untuk rekonsiliasi data sebelum jam kerja dimulai.
    * **Jika jam 09:00 atau setelahnya**: Ia menjalankan `sync_presensi_only.sh` untuk melakukan sinkronisasi inkremental per kantor.

3.  **Sinkronisasi Inkremental (`sync_presensi_only.sh`)**:
    * Berjalan di jam kerja, skrip ini memproses **satu kantor** pada satu waktu secara bergantian.
    * Memiliki dua jendela waktu: **pagi (09:00-17:59)** dan **sore (18:00-23:59)**. Setiap kantor hanya akan diproses satu kali per jendela waktu.
    * Jika berhasil memasukkan data baru ke tabel `presensi`, skrip ini akan **otomatis memicu** `sync_to_scanlog.sh`.

4.  **Proses ETL (`sync_to_scanlog.sh`)**:
    * Skrip ini mencari semua data di tabel `presensi` yang memiliki flag `sync = 0`.
    * Data waktu (`jam_pagi`, `jam_siang`, `jam_sore`) dari baris tersebut dipindahkan ke tabel `tb_scanlog_ars`.
    * Setelah berhasil dipindahkan, flag `sync` di tabel `presensi` diubah menjadi `1`.
    * Mengirimkan laporan ringkas ke Telegram jika ada data yang diproses.

---

## 📂 Komponen Skrip

* `cron_dispatcher.sh`: Bertindak sebagai *entry point* utama yang dipanggil oleh cron. Mengarahkan eksekusi ke skrip yang tepat berdasarkan waktu.
* `sync_presensi_range.sh`: Digunakan untuk sinkronisasi massal data historis (misalnya, 7 hari terakhir). Dilengkapi dengan statistik panggilan API.
* `sync_presensi_only.sh`: Digunakan untuk sinkronisasi terjadwal per kantor. Berjalan secara inkremental dan memiliki logika jendela waktu.
* `sync_to_scanlog.sh`: Bertanggung jawab untuk memindahkan data dari tabel `presensi` ke `tb_scanlog_ars` dan memperbarui status `sync`.

---

## 🗃️ Struktur Database

Database `pegawai_db` menggunakan tiga tabel utama yang saling berhubungan untuk mengelola alur kerja ini.

### `tb_pegawai`

Tabel ini berfungsi sebagai **tabel master** yang menyimpan data induk untuk setiap pegawai. Peran utamanya adalah sebagai "kamus" untuk menerjemahkan **NIP** menjadi **PIN** (ID unik internal).

* `pin` (bigint, Primary Key): ID unik untuk setiap pegawai yang digunakan sebagai referensi di tabel `tb_scanlog_ars`.
* `nama` (varchar): Nama lengkap pegawai.
* `nip` (bigint): Nomor Induk Pegawai. Kolom ini menjadi kunci penghubung ke tabel `presensi`.
* `instansi` (int): Kode atau ID instansi tempat pegawai bekerja.

### `presensi`

Tabel ini berfungsi sebagai **tabel sementara** atau *staging area*. Data yang diambil dari API Simpegnas BKN pertama kali dimasukkan ke sini.

* `id` (int, Primary Key, Auto Increment): ID unik untuk setiap baris data presensi.
* `nip` (varchar): NIP pegawai yang melakukan absensi.
* `tgl` (date): Tanggal presensi.
* `jam_pagi`, `jam_siang`, `jam_sore` (time): Catatan waktu absensi yang menjadi target utama untuk dipindahkan.
* `sync` (tinyint): Kolom ini adalah **flag** atau penanda status pemrosesan.
    * **`0`**: Menandakan data ini baru dan siap dipindahkan ke `tb_scanlog_ars`.
    * **`1`**: Menandakan data ini sudah selesai diproses.

Tabel ini juga memiliki `UNIQUE KEY` pada kolom (`nip`, `tgl`) untuk memastikan tidak ada data ganda untuk pegawai yang sama pada tanggal yang sama.

### `tb_scanlog_ars`

Tabel ini berfungsi sebagai **tabel arsip** atau tujuan akhir dari data waktu absensi yang sudah bersih dan tervalidasi. Setiap catatan waktu (pagi, siang, atau sore) disimpan sebagai satu baris terpisah di sini.

* `id` (bigint, Primary Key, Auto Increment): ID unik untuk setiap entri log.
* `scan_date` (timestamp): Menyimpan gabungan informasi tanggal dan waktu absensi (contoh: '2025-10-07 07:59:43').
* `pin` (text): ID unik pegawai yang diambil dari tabel `tb_pegawai`.

---

## 🛠️ Instalasi & Konfigurasi

### 1. Prasyarat

Pastikan server Anda memiliki:
* `bash`
* `mysql-client`
* `jq` (untuk memproses JSON)
* `curl` (untuk panggilan API)

### 2. Kloning Repositori
```bash
git clone [https://github.com/cedirusyaid/sinkronisasi-presensi.git](https://github.com/cedirusyaid/sinkronisasi-presensi.git)
cd sinkronisasi-presensi
