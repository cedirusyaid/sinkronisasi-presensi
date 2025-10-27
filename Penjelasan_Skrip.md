# Penjelasan Fungsi Skrip Sinkronisasi Presensi

Dokumen ini menjelaskan fungsionalitas dari setiap skrip `.sh` yang ada di dalam direktori ini.

---

## 1. `cron_dispatcher.sh`

**Fungsi Utama:** Bertindak sebagai skrip pemandu (dispatcher) utama yang dijalankan oleh cron job secara periodik.

**Alur Kerja:**
- Mengecek apakah hari ini adalah hari kerja (Senin-Jumat). Jika akhir pekan, proses berhenti.
- Berdasarkan waktu eksekusi:
    - **Sebelum jam 9 pagi:** Menjalankan `sync_presensi_range.sh` untuk mengambil data presensi dalam rentang beberapa hari ke belakang (mode "catch-up").
    - **Jam 9 pagi atau setelahnya:** Menjalankan `sync_presensi_only.sh` untuk mengambil data presensi hari ini secara bertahap per kantor.

---

## 2. `sync_presensi_range.sh`

**Fungsi Utama:** Mengambil data presensi dari API secara massal untuk rentang waktu yang panjang (misalnya 7 hari terakhir).

**Alur Kerja:**
- Mengambil daftar semua kantor dari API.
- Untuk setiap hari dalam rentang yang ditentukan, skrip akan melakukan loop ke semua kantor.
- Mengambil data rekap presensi dari API untuk setiap kantor pada tanggal tersebut.
- Memasukkan atau memperbarui data yang diterima ke dalam tabel `presensi` di database.
- **Jika ada data baru yang diinput, skrip ini akan memicu eksekusi `sync_to_scanlog.sh`.**
- Mengirimkan laporan ringkasan ke Telegram setelah semua proses selesai, dengan durasi eksekusi yang diformat (menit/detik).
- Membuat file `.lock` untuk mencegah eksekusi ganda pada hari yang sama, dan **menghapus file `.lock` dari hari sebelumnya.**

---

## 3. `sync_presensi_only.sh`

**Fungsi Utama:** Melakukan sinkronisasi data presensi untuk hari ini saja, dengan cara memproses satu kantor pada satu waktu secara bergantian.

**Alur Kerja:**
- Menentukan periode waktu (pagi/sore).
- Menggunakan file `last_office_index.txt` untuk menentukan kantor mana yang harus diproses selanjutnya agar semua kantor mendapat giliran.
- Mengambil data presensi dari API hanya untuk satu kantor yang dipilih.
- Memasukkan atau memperbarui data ke tabel `presensi`.
- **Penting:** Jika ada data baru yang berhasil dimasukkan, skrip ini akan secara otomatis memicu eksekusi `sync_to_scanlog.sh`.
- **Mengirim laporan status per kantor ke Telegram hanya jika ada data yang diinput atau terjadi error, dengan menyertakan `kantor_id` dalam tag laporan.**

---

## 4. `sync_to_scanlog.sh`

**Fungsi Utama:** Mentransformasi dan memindahkan data dari tabel `presensi` (yang berisi data matang) ke dalam tabel `tb_scanlog_ars` (yang meniru format data mentah dari mesin absensi).

**Alur Kerja:**
- Mencari data di tabel `presensi` yang belum diproses (`sync = 0`).
- Untuk setiap data presensi (yang bisa memiliki jam pagi, siang, sore):
    - Mengambil NIP dan mencari `pin` pegawai yang sesuai.
    - Mengubah setiap entri jam menjadi baris data terpisah di `tb_scanlog_ars` dengan format `pin` dan `scan_date`.
    - Melakukan pengecekan duplikasi untuk menghindari data ganda.
- Setelah selesai, memperbarui status di tabel `presensi` menjadi `sync = 1` agar tidak diproses lagi.