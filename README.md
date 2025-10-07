Mohon maaf atas kendalanya. Terkadang tautan unduhan bisa mengalami masalah.

Sebagai gantinya, berikut adalah isi lengkap dari file `README.md` dalam format teks biasa yang bisa Anda salin dan tempel langsung. Ini adalah cara yang paling andal.

````text
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
* `tgl` (date): Tanggal absensi.
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
````

### 3\. Setup Database

Impor file `pegawai_db.sql` yang tersedia ke dalam server MySQL Anda.

```bash
mysql -u username -p nama_database < pegawai_db.sql
```

### 4\. Konfigurasi Environment (`.env`)

Buat file `.env` di direktori utama proyek. File ini berisi semua informasi sensitif dan konfigurasi.

```ini
# Konfigurasi Database MySQL
DB_HOST="localhost"
DB_USER="user_database"
DB_PASS="password_database"
DB_NAME="pegawai_db"

# Kunci API Presensi Simpegnas BKN
API_KEY="KUNCI_API_ANDA"

# --- Konfigurasi Notifikasi Telegram ---
# Token Bot yang didapat dari @BotFather
TELEGRAM_BOT_TOKEN="TOKEN_BOT_TELEGRAM_ANDA"

# Chat ID tujuan (bisa ID personal atau ID grup)
TELEGRAM_CHAT_ID="CHAT_ID_TUJUAN_ANDA"
```

#### Penjelasan Variabel `.env`:

  * **`DB_HOST`**: Alamat server database Anda (biasanya `localhost`).
  * **`DB_USER`**: Nama pengguna untuk login ke database.
  * **`DB_PASS`**: Kata sandi untuk pengguna database tersebut.
  * **`DB_NAME`**: Nama database yang Anda gunakan.
  * **`API_KEY`**: Kunci API atau token otorisasi yang Anda dapatkan dari penyedia layanan (Simpegnas BKN) untuk mengakses data presensi.
  * **`TELEGRAM_BOT_TOKEN`**: Token unik untuk bot Telegram Anda.
      * **Cara mendapatkan**: Buka Telegram, cari bot bernama `@BotFather`, mulai percakapan, dan ikuti perintah untuk membuat bot baru (`/newbot`). BotFather akan memberikan token ini.
  * **`TELEGRAM_CHAT_ID`**: ID unik dari pengguna, grup, atau channel Telegram yang akan menerima notifikasi.
      * **Cara mendapatkan (Chat Pribadi)**: Kirim pesan ke bot `@userinfobot`, dan ia akan membalas dengan User ID Anda.
      * **Cara mendapatkan (Grup/Channel)**:
        1.  Tambahkan bot Anda ke dalam grup atau channel.
        2.  Kirim pesan apa pun ke grup/channel tersebut.
        3.  Buka browser dan akses URL berikut (ganti `TOKEN_BOT_ANDA` dengan token bot Anda): `https://api.telegram.org/botTOKEN_BOT_ANDA/getUpdates`.
        4.  Cari objek `chat`, dan temukan `id`. ID untuk grup/channel biasanya diawali dengan tanda minus (`-`).

### 5\. Atur Hak Akses

Jadikan semua skrip dapat dieksekusi:

```bash
chmod +x *.sh
```

-----

## 🚀 Penggunaan

### Menjalankan dengan Cron (Direkomendasikan)

Cara terbaik untuk menjalankan sistem ini adalah melalui `cron`. Hapus semua jadwal cron lama dan ganti dengan **satu baris** yang memanggil `cron_dispatcher.sh`.

1.  Buka editor crontab:

    ```bash
    crontab -e
    ```

2.  Tambahkan baris berikut (contoh berjalan setiap 10 menit):

    ```crontab
    */10 * * * * /path/lengkap/ke/folder/sinkronisasi-presensi/cron_dispatcher.sh >> /path/lengkap/ke/folder/sinkronisasi-presensi/dispatcher.log 2>&1
    ```

      * Pastikan untuk menggunakan **path absolut** ke skrip Anda.
      * `>> ... dispatcher.log 2>&1` akan menyimpan semua log eksekusi ke file `dispatcher.log`, yang sangat berguna untuk debugging.

### Menjalankan Manual

Anda juga bisa menjalankan setiap skrip secara manual untuk keperluan pengujian. Pastikan Anda berada di dalam direktori proyek.

  * **Menjalankan alur utama (sesuai jam):**
    ```bash
    ./cron_dispatcher.sh
    ```
  * **Menjalankan sinkronisasi massal untuk 30 hari:**
    ```bash
    ./sync_presensi_range.sh 30
    ```
  * **Menjalankan pemindahan data ke scanlog secara manual:**
    ```bash
    ./sync_to_scanlog.sh
    ```

<!-- end list -->

```
