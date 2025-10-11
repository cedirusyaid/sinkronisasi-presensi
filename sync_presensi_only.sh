#!/bin/bash

# --- Memulai Timer ---
START_TIME=$(date +%s)

# ========================================================================
# Logika Waktu dan Penentuan Periode
# ========================================================================
CURRENT_HOUR=$(date +%-H)
TODAY=$(date +%Y-%m-%d)
LOG_DIR="run_logs"
STATE_FILE="last_office_index.txt"

# Tentukan periode berdasarkan jam saat ini
if (( CURRENT_HOUR >= 9 && CURRENT_HOUR <= 17 )); then
    WINDOW="pagi"
elif (( CURRENT_HOUR >= 18 && CURRENT_HOUR <= 23 )); then
    WINDOW="sore"
else
    echo "Di luar jam operasional (09:00-17:59 & 18:00-23:59). Proses diabaikan."
    exit 0
fi
echo "Periode saat ini: ${WINDOW}"

# Buat direktori log jika belum ada
mkdir -p "$LOG_DIR"

# --- Pengecekan Dependency ---
if ! command -v jq &> /dev/null; then echo "Error: 'jq' tidak ditemukan."; exit 1; fi
if ! command -v mysql &> /dev/null; then echo "Error: 'mysql' client tidak ditemukan."; exit 1; fi

# --- Memuat Konfigurasi dari .env ---
if [ ! -f .env ]; then echo "Error: File .env tidak ditemukan."; exit 1; fi
export $(grep -v '^#' .env | xargs)

# --- Menentukan Tanggal Target ---
TARGET_DATE=${1:-$(date +%Y-%m-%d)}
echo "✅ Konfigurasi dimuat. Proses akan berjalan untuk tanggal: ${TARGET_DATE}"

# --- API Endpoints ---
API_KANTOR_URL="https://api-absensi.simpegnas.go.id/absensi/api/get/kantor"
API_PRESENSI_URL="https://api-absensi.simpegnas.go.id/absensi/api/get/rekap-by-kantor"

# --- Mengambil Daftar Semua Kantor ---
KANTOR_RESPONSE=$(curl -s -X 'GET' "${API_KANTOR_URL}" -H 'accept: */*' -H "presensi-key: ${API_KEY}")
ALL_KANTOR=$(echo "$KANTOR_RESPONSE" | jq -c '.data.kantor')
TOTAL_KANTOR=$(echo "$ALL_KANTOR" | jq 'length' 2>/dev/null)

if ! [[ "$TOTAL_KANTOR" =~ ^[0-9]+$ ]]; then
    echo "❌ ERROR: Gagal mendapatkan daftar kantor dari API atau format data tidak valid."
    echo "   Respons Mentah dari API: ${KANTOR_RESPONSE}"
    exit 1
fi

if [ "$TOTAL_KANTOR" -eq 0 ]; then
    echo "❌ Tidak ada data kantor yang ditemukan dari API. Proses dihentikan."
    exit 1
fi

# --- Cari kantor berikutnya yang belum diproses di periode ini ---
START_INDEX=$(cat "${STATE_FILE}" 2>/dev/null || echo 0)
KANTOR_TO_PROCESS=""
PROCESSED_INDEX=-1

echo "Mencari kantor yang belum diproses untuk periode '${WINDOW}'..."
for (( i=0; i<TOTAL_KANTOR; i++ )); do
    CURRENT_INDEX=$(( (START_INDEX + i) % TOTAL_KANTOR ))
    
    temp_kantor=$(echo "$ALL_KANTOR" | jq ".[$CURRENT_INDEX]")
    kantor_id=$(echo "$temp_kantor" | jq -r '.id')
    
    LOCK_FILE="${LOG_DIR}/${TODAY}_${kantor_id}_${WINDOW}.lock"
    
    if [ ! -f "${LOCK_FILE}" ]; then
        KANTOR_TO_PROCESS=$temp_kantor
        PROCESSED_INDEX=$CURRENT_INDEX
        break
    fi
done

if [ -z "$KANTOR_TO_PROCESS" ]; then
    echo "✅ Semua kantor sudah diproses untuk periode '${WINDOW}' hari ini. Selesai."
    exit 0
fi

# --- Variabel Laporan ---
REPORT_MESSAGE="📅 *Laporan Update Presensi (${WINDOW})* 📅"
REPORT_MESSAGE+=$'\n\n'"*Tanggal:* ${TARGET_DATE}"

# --- Proses satu kantor yang sudah dipilih ---
kantor_id=$(echo "$KANTOR_TO_PROCESS" | jq -r '.id')
nama_kantor=$(echo "$KANTOR_TO_PROCESS" | jq -r '.nama_kantor')
inserted_this_office=0

echo -e "\n--- Tahap 2: Memproses data presensi untuk: ${nama_kantor} ---"
PRESENSI_RESPONSE=$(curl -s -X 'GET' "${API_PRESENSI_URL}?kantor_id=${kantor_id}&start_date=${TARGET_DATE}&end_date=${TARGET_DATE}" -H 'accept: */*' -H "presensi-key: ${API_KEY}")
pegawai_count_from_api=$(echo "$PRESENSI_RESPONSE" | jq '.data | length' 2>/dev/null)

if ! [[ "$pegawai_count_from_api" =~ ^[0-9]+$ ]] || [ "$pegawai_count_from_api" -eq 0 ]; then
    echo "  -> Tidak ada data presensi dari API untuk kantor ini."
else
    echo "  -> Diterima ${pegawai_count_from_api} data. Memfilter dan memproses..."
    
    while read -r pegawai; do
        nip=$(echo "$pegawai" | jq -r '.nip')
        while read -r presensi; do
            jam_pagi=$(echo "$presensi" | jq -r '.jam_pagi'); jam_siang=$(echo "$presensi" | jq -r '.jam_siang'); jam_sore=$(echo "$presensi" | jq -r '.jam_sore');
            if [ "$jam_pagi" == "null" ] && [ "$jam_siang" == "null" ] && [ "$jam_sore" == "null" ]; then continue; fi
            tgl=$(echo "$presensi" | jq -r '.tgl'); pagi=$(echo "$presensi" | jq -r '.pagi'); siang=$(echo "$presensi" | jq -r '.siang'); sore=$(echo "$presensi" | jq -r '.sore'); keterangan=$(echo "$presensi" | jq -r '.keterangan');
            jam_pagi_sql=$([ "$jam_pagi" == "null" ] && echo "NULL" || echo "'$jam_pagi'"); jam_siang_sql=$([ "$jam_siang" == "null" ] && echo "NULL" || echo "'$jam_siang'"); jam_sore_sql=$([ "$jam_sore" == "null" ] && echo "NULL" || echo "'$jam_sore'");
            SQL_PRESENSI="INSERT INTO presensi (nip, tgl, pagi, siang, sore, jam_pagi, jam_siang, jam_sore, keterangan) VALUES ('${nip}', '${tgl}', '${pagi}', '${siang}', '${sore}', ${jam_pagi_sql}, ${jam_siang_sql}, ${jam_sore_sql}, '${keterangan}') ON DUPLICATE KEY UPDATE pagi = VALUES(pagi), siang = VALUES(siang), sore = VALUES(sore), jam_pagi = VALUES(jam_pagi), jam_siang = VALUES(jam_siang), jam_sore = VALUES(jam_sore), keterangan = VALUES(keterangan);";
            
            # Menjalankan query dan menangkap output error
            ERROR_OUTPUT=$(mysql -h"${DB_HOST}" -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" -e "${SQL_PRESENSI}" 2>&1)
            EXIT_CODE=$?

            # Cek jika ada error
            if [ ${EXIT_CODE} -ne 0 ]; then
                echo ""
                echo "--- MYSQL ERROR ---"
                echo "Gagal menjalankan query untuk NIP: ${nip} pada tanggal ${tgl}"
                echo "Error: ${ERROR_OUTPUT}"
                echo "-------------------"
                echo ""
            else
                # Hanya increment jika berhasil
                inserted_this_office=$((inserted_this_office + 1));
            fi
        done < <(echo "$pegawai" | jq -c '.presensi[]');
    done < <(echo "$PRESENSI_RESPONSE" | jq -c '.data[]');
fi

# ========================================================================
# PERUBAHAN BARU: Jalankan sync_to_scanlog.sh jika ada data yang diinput
# ========================================================================
if [ "$inserted_this_office" -gt 0 ]; then
    echo "   -> ${inserted_this_office} data baru diinput. Memicu sync_to_scanlog.sh..."
    ./sync_to_scanlog.sh
fi

# --- Laporan dan Pengiriman ---
REPORT_MESSAGE+=$'\n\n'"✅ *${nama_kantor}*"
REPORT_MESSAGE+=$'\n'"*Data Diinput:* ${inserted_this_office} data"
END_TIME=$(date +%s); DURATION=$((END_TIME - START_TIME));
REPORT_MESSAGE+=$'\n'"⏱️ *Durasi Eksekusi:* ${DURATION} detik"

echo -e "\n--- Tahap 3: Mengirim laporan ke Telegram ---"
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${REPORT_MESSAGE}" --data-urlencode "parse_mode=Markdown" > /dev/null
echo "✅ Laporan berhasil dikirim."

# --- Buat lock file dan update indeks ---
FINAL_LOCK_FILE="${LOG_DIR}/${TODAY}_${kantor_id}_${WINDOW}.lock"
touch "${FINAL_LOCK_FILE}"
echo "✅ Lock file dibuat: ${FINAL_LOCK_FILE}"

NEXT_INDEX=$(( (PROCESSED_INDEX + 1) % TOTAL_KANTOR ))
echo "${NEXT_INDEX}" > "${STATE_FILE}"

echo -e "\n🎉 Proses untuk kantor ${nama_kantor} telah selesai."
