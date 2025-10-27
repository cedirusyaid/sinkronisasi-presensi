#!/bin/bash

# ========================================================================
# PERUBAHAN 1: Inisialisasi variabel untuk statistik API
# ========================================================================
TOTAL_API_CALLS=0
SUCCESS_API_CALLS=0
FAILED_API_CALLS=0

# Cek apakah proses untuk hari ini sudah pernah berhasil.
TODAY=$(date +%Y-%m-%d)
LOCK_FILE="sync_complete_${TODAY}.lock"

if [ -f "${LOCK_FILE}" ]; then
    echo "✅ Proses untuk tanggal ${TODAY} sudah pernah berhasil dijalankan sebelumnya."
    echo "   Proses dihentikan. Hapus file '${LOCK_FILE}' untuk menjalankan ulang."
    exit 0
fi

# Ambil jumlah hari dari argumen. Default adalah 1.
DAYS_TO_FETCH=${1:-1}

# --- Memulai Timer ---
START_TIME=$(date +%s)

# --- Pengecekan Dependency ---
if ! command -v jq &> /dev/null; then echo "Error: 'jq' tidak ditemukan."; exit 1; fi
if ! command -v mysql &> /dev/null; then echo "Error: 'mysql' client tidak ditemukan."; exit 1; fi

# --- Memuat Konfigurasi dari .env ---
if [ ! -f .env ]; then echo "Error: File .env tidak ditemukan."; exit 1; fi
export $(grep -v '^#' .env | xargs)

echo "✅ Konfigurasi dimuat. Proses akan mengambil data untuk ${DAYS_TO_FETCH} hari terakhir."

# --- API Endpoints ---
API_KANTOR_URL="https://api-absensi.simpegnas.go.id/absensi/api/get/kantor"
API_PRESENSI_URL="https://api-absensi.simpegnas.go.id/absensi/api/get/rekap-by-kantor"

# --- Variabel untuk Laporan ---
START_DATE_REPORT=$(date -d "$((DAYS_TO_FETCH - 1)) days ago" +%Y-%m-%d)
END_DATE_REPORT=$(date +%Y-%m-%d)
REPORT_MESSAGE="📅 *Laporan Update #PresensiMassal* 📅"
REPORT_MESSAGE+=$'\n\n'"*Periode:* ${DAYS_TO_FETCH} hari (${START_DATE_REPORT} s/d ${END_DATE_REPORT})"
TOTAL_DATA_DIINPUT=0

# === TAHAP 1: Mengambil Daftar Kantor dari API (Cukup sekali) ===
echo -e "\n--- Tahap 1: Mengambil daftar kantor dari API ---"
TOTAL_API_CALLS=$((TOTAL_API_CALLS + 1))
KANTOR_RESPONSE=$(curl -s -X 'GET' "${API_KANTOR_URL}" -H 'accept: */*' -H "presensi-key: ${API_KEY}")
ALL_KANTOR=$(echo "$KANTOR_RESPONSE" | jq -c '.data.kantor')
TOTAL_KANTOR=$(echo "$ALL_KANTOR" | jq 'length' 2>/dev/null)

if ! [[ "$TOTAL_KANTOR" =~ ^[0-9]+$ ]]; then
    FAILED_API_CALLS=$((FAILED_API_CALLS + 1))
    echo "❌ ERROR FATAL: Gagal mendapatkan daftar kantor dari API. Proses dihentikan."
    echo "   Respons Mentah dari API: ${KANTOR_RESPONSE}"
    exit 1
else
    SUCCESS_API_CALLS=$((SUCCESS_API_CALLS + 1))
    echo "✅ Daftar kantor berhasil diambil."
fi

# Loop untuk setiap hari dalam rentang waktu yang ditentukan
for (( i=($DAYS_TO_FETCH-1); i>=0; i-- )); do
    
    TARGET_DATE=$(date -d "$i days ago" +%Y-%m-%d)
    echo -e "\n================================================="
    echo "         Memproses data untuk TANGGAL: ${TARGET_DATE}"
    echo "================================================="

    # === TAHAP 2: Mengambil dan Memfilter Data Presensi (di dalam loop tanggal) ===
    while read -r kantor; do
        kantor_id=$(echo "$kantor" | jq -r '.id')
        nama_kantor=$(echo "$kantor" | jq -r '.nama_kantor')
        
        inserted_this_office_per_day=0

        echo -e "\n🏢 Memproses kantor: ${nama_kantor}"
        
        # ========================================================================
        # PERUBAHAN 2: Hitung dan validasi API call untuk setiap kantor
        # ========================================================================
        TOTAL_API_CALLS=$((TOTAL_API_CALLS + 1))
        PRESENSI_RESPONSE=$(curl -s -X 'GET' \
          "${API_PRESENSI_URL}?kantor_id=${kantor_id}&start_date=${TARGET_DATE}&end_date=${TARGET_DATE}" \
          -H 'accept: */*' \
          -H "presensi-key: ${API_KEY}")
          
        pegawai_count_from_api=$(echo "$PRESENSI_RESPONSE" | jq '.data | length' 2>/dev/null)
        
        if ! [[ "$pegawai_count_from_api" =~ ^[0-9]+$ ]]; then
            FAILED_API_CALLS=$((FAILED_API_CALLS + 1))
            echo "  -> ❌ Gagal: Respons API tidak valid untuk kantor ini."
            continue # Lanjut ke kantor berikutnya
        fi

        SUCCESS_API_CALLS=$((SUCCESS_API_CALLS + 1))
        
        if [ "$pegawai_count_from_api" -eq 0 ]; then
            echo "  -> Tidak ada data dari API."
            continue
        fi
        
        echo "  -> Diterima ${pegawai_count_from_api} data. Memfilter dan memproses..."
        
        while read -r pegawai; do
            nip=$(echo "$pegawai" | jq -r '.nip')
            while read -r presensi; do
                jam_pagi=$(echo "$presensi" | jq -r '.jam_pagi'); jam_siang=$(echo "$presensi" | jq -r '.jam_siang'); jam_sore=$(echo "$presensi" | jq -r '.sore');
                if [ "$jam_pagi" == "null" ] && [ "$jam_siang" == "null" ] && [ "$jam_sore" == "null" ]; then continue; fi
                tgl=$(echo "$presensi" | jq -r '.tgl'); pagi=$(echo "$presensi" | jq -r '.pagi'); siang=$(echo "$presensi" | jq -r '.siang'); sore=$(echo "$presensi" | jq -r '.sore'); keterangan=$(echo "$presensi" | jq -r '.keterangan');
                jam_pagi_sql=$([ "$jam_pagi" == "null" ] && echo "NULL" || echo "'$jam_pagi'"); jam_siang_sql=$([ "$jam_siang" == "null" ] && echo "NULL" || echo "'$jam_siang'"); jam_sore_sql=$([ "$jam_sore" == "null" ] && echo "NULL" || echo "'$jam_sore'");
                SQL_PRESENSI="INSERT INTO presensi (nip, tgl, pagi, siang, sore, jam_pagi, jam_siang, jam_sore, keterangan) VALUES ('${nip}', '${tgl}', '${pagi}', '${siang}', '${sore}', ${jam_pagi_sql}, ${jam_siang_sql}, ${jam_sore_sql}, '${keterangan}') ON DUPLICATE KEY UPDATE pagi = VALUES(pagi), siang = VALUES(siang), sore = VALUES(sore), jam_pagi = VALUES(jam_pagi), jam_siang = VALUES(jam_siang), jam_sore = VALUES(jam_sore), keterangan = VALUES(keterangan);";
                mysql -h"${DB_HOST}" -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" -e "${SQL_PRESENSI}";
                inserted_this_office_per_day=$((inserted_this_office_per_day + 1));
            done < <(echo "$pegawai" | jq -c '.presensi[]');
        done < <(echo "$PRESENSI_RESPONSE" | jq -c '.data[]');
        
        if [ "$inserted_this_office_per_day" -gt 0 ]; then
            echo "  -> Berhasil input ${inserted_this_office_per_day} data untuk ${nama_kantor} pada ${TARGET_DATE}"
        fi
        
        TOTAL_DATA_DIINPUT=$((TOTAL_DATA_DIINPUT + inserted_this_office_per_day))
        
    done < <(echo "$KANTOR_RESPONSE" | jq -c '.data.kantor[]')

done # Akhir dari loop tanggal

if [ "$TOTAL_DATA_DIINPUT" -gt 0 ]; then
    echo "   -> ${TOTAL_DATA_DIINPUT} data baru diinput. Memicu sync_to_scanlog.sh..."
    ./sync_to_scanlog.sh
fi

# === TAHAP BARU: Membersihkan Log Lama ===
echo -e "\n--- Tahap Pembersihan: Menghapus file log lama ---"
# Cari file di run_logs yang lebih tua dari 1 hari dan hapus
DELETED_LOG_COUNT=$(find run_logs/ -type f -mtime +0 -print | wc -l)
CLEANUP_REPORT_MSG=""
if [ "$DELETED_LOG_COUNT" -gt 0 ]; then
    find run_logs/ -type f -mtime +0 -delete
    echo "✅ Berhasil menghapus ${DELETED_LOG_COUNT} file log."
    CLEANUP_REPORT_MSG=$'\n'"🧹 *Pembersihan:* ${DELETED_LOG_COUNT} log lama dihapus."
else
    echo "✅ Tidak ada file log lama yang perlu dihapus."
fi

# --- Menghitung Durasi Eksekusi ---
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

FORMATTED_DURATION=""
if (( DURATION >= 60 )); then
    MINUTES=$((DURATION / 60))
    SECONDS=$((DURATION % 60))
    FORMATTED_DURATION="${MINUTES} menit ${SECONDS} detik"
else
    FORMATTED_DURATION="${DURATION} detik"
fi

# === TAHAP 3: Mengirim Laporan ke Telegram ===
echo -e "\n--- Tahap 3: Mengirim laporan ke Telegram ---"

REPORT_MESSAGE+=$'\n\n'"--- *Ringkasan* ---"
REPORT_MESSAGE+=$'\n'"📊 *Total Data Diinput:* ${TOTAL_DATA_DIINPUT}"
REPORT_MESSAGE+=$'\n'"⏱️ *Durasi Eksekusi:* ${FORMATTED_DURATION}"
REPORT_MESSAGE+="${CLEANUP_REPORT_MSG}"

# ========================================================================
# PERUBAHAN 3: Tambahkan blok statistik API ke dalam laporan
# ========================================================================
REPORT_MESSAGE+=$'\n\n'"--- *Statistik API* ---"
REPORT_MESSAGE+=$'\n'"📞 *Total Panggilan:* ${TOTAL_API_CALLS}"
REPORT_MESSAGE+=$'\n'"✔️ *Berhasil:* ${SUCCESS_API_CALLS}"
REPORT_MESSAGE+=$'\n'"❌ *Gagal:* ${FAILED_API_CALLS}"

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${REPORT_MESSAGE}" \
    --data-urlencode "parse_mode=Markdown"

echo "✅ Laporan berhasil dikirim."

# Buat file penanda bahwa proses hari ini telah selesai.
touch "${LOCK_FILE}"
echo "✅ Lock file dibuat. Proses tidak akan berjalan lagi hari ini."

# Hapus lock file dari hari sebelumnya
YESTERDAY=$(date -d "yesterday" +%Y-%m-%d)
YESTERDAY_LOCK_FILE="sync_complete_${YESTERDAY}.lock"
if [ -f "${YESTERDAY_LOCK_FILE}" ]; then
    rm -f "${YESTERDAY_LOCK_FILE}"
    echo "✅ Lock file kemarin (${YESTERDAY_LOCK_FILE}) berhasil dihapus."
else
    echo "☑️ Tidak ada lock file kemarin (${YESTERDAY_LOCK_FILE}) untuk dihapus."
fi

echo -e "\n🎉 Semua proses telah selesai."
