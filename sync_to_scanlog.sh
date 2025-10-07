#!/bin/bash

# --- Memulai Timer ---
START_TIME=$(date +%s)

# --- Pengecekan Dependency ---
if ! command -v mysql &> /dev/null; then
    echo "Error: 'mysql' client tidak ditemukan."
    exit 1
fi

# --- Memuat Konfigurasi dari .env ---
if [ ! -f .env ]; then
    echo "Error: File .env tidak ditemukan."
    exit 1
fi
export $(grep -v '^#' .env | xargs)

# --- Variabel untuk Laporan ---
TOTAL_BARIS_DIPROSES=0
TOTAL_DATA_DIINPUT=0
PROCESSED_IDS=""

echo "✅ Konfigurasi dimuat. Memulai proses sinkronisasi ke tb_scanlog_ars..."

# --- Fungsi untuk menjalankan kueri SQL dan mendapatkan output ---
function run_sql() {
    mysql -h"${DB_HOST}" -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" -N -e "$1"
}

# --- Tahap 1: Ambil data dari tabel 'presensi' yang belum sinkron (sync = 0) ---
SQL_SELECT_PRESENSI="SELECT id, nip, tgl, jam_pagi, jam_siang, jam_sore FROM presensi WHERE sync = 0;"

# ========================================================================
# PERUBAHAN UTAMA: Gunakan process substitution (< <(...)) untuk menghindari subshell
# ========================================================================
while IFS=$'\t' read -r id nip tgl jam_pagi jam_siang jam_sore; do
    
    echo -e "\n🔄 Memproses presensi ID: ${id} untuk NIP: ${nip} pada tanggal ${tgl}"
    TOTAL_BARIS_DIPROSES=$((TOTAL_BARIS_DIPROSES + 1))
    
    # --- Ambil 'pin' dari tb_pegawai berdasarkan 'nip' ---
    PIN=$(run_sql "SELECT pin FROM tb_pegawai WHERE nip='${nip}' LIMIT 1;")
    
    if [ -z "$PIN" ]; then
        echo "   -> ⚠️  Peringatan: NIP ${nip} tidak ditemukan di tb_pegawai. Melewati baris ini."
        continue
    fi
    
    echo "   -> Ditemukan PIN: ${PIN} untuk NIP: ${nip}"
    
    # --- Proses setiap waktu (pagi, siang, sore) ---
    for jam in "$jam_pagi" "$jam_siang" "$jam_sore"; do
        # Lewati jika jam adalah 'NULL' atau kosong
        if [ "$jam" == "NULL" ] || [ -z "$jam" ]; then
            continue
        fi

        SCAN_DATE="${tgl} ${jam}"
        
        # --- Cek duplikasi di tb_scanlog_ars ---
        CHECK_DUPLICATE=$(run_sql "SELECT COUNT(*) FROM tb_scanlog_ars WHERE pin='${PIN}' AND scan_date='${SCAN_DATE}';")
        
        if [ "$CHECK_DUPLICATE" -gt 0 ]; then
            echo "   -> ⏭️  SKIP: Data untuk PIN ${PIN} pada ${SCAN_DATE} sudah ada."
        else
            # --- Masukkan data ke tb_scanlog_ars ---
            SQL_INSERT_SCANLOG="INSERT INTO tb_scanlog_ars (sn, scan_date, pin) VALUES ('sync_script', '${SCAN_DATE}', '${PIN}');"
            run_sql "${SQL_INSERT_SCANLOG}"
            
            if [ $? -eq 0 ]; then
                echo "   -> ✅ INSERT: Berhasil memasukkan data untuk ${SCAN_DATE}."
                TOTAL_DATA_DIINPUT=$((TOTAL_DATA_DIINPUT + 1))
            else
                echo "   -> ❌ GAGAL: Terjadi masalah saat memasukkan data untuk ${SCAN_DATE}."
            fi
        fi
    done
    
    # Kumpulkan ID dari baris presensi yang telah diproses
    if [ -z "$PROCESSED_IDS" ]; then
        PROCESSED_IDS="${id}"
    else
        PROCESSED_IDS="${PROCESSED_IDS},${id}"
    fi
    
done < <(run_sql "${SQL_SELECT_PRESENSI}")

# --- Tahap 2: Update kolom 'sync' menjadi 1 untuk semua ID yang telah diproses ---
if [ ! -z "$PROCESSED_IDS" ]; then
    echo -e "\n--- Memperbarui status 'sync' untuk ID: ${PROCESSED_IDS} ---"
    SQL_UPDATE_SYNC="UPDATE presensi SET sync = 1 WHERE id IN (${PROCESSED_IDS});"
    run_sql "${SQL_UPDATE_SYNC}"
    echo "✅ Status 'sync' berhasil diperbarui."
else
    echo -e "\nTidak ada data baru untuk disinkronkan."
fi

# --- Laporan Akhir ---
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo -e "\n--- Laporan Sinkronisasi ---"
echo "⏱️ Durasi Eksekusi   : ${DURATION} detik"
echo "🔄 Baris Divalidasi  : ${TOTAL_BARIS_DIPROSES}"
echo "➕ Data Baru Diinput : ${TOTAL_DATA_DIINPUT}"
echo "🎉 Proses sinkronisasi selesai."