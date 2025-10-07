#!/bin/bash

# ========================================================================
# Script Pemandu (Dispatcher) untuk Cron Job Presensi
# ========================================================================

# Pindah ke direktori tempat script ini berada.
# Ini PENTING agar script lain dan file .env dapat ditemukan.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "$SCRIPT_DIR"

# Dapatkan jam saat ini dalam format 24 jam (tanpa nol di depan)
CURRENT_HOUR=$(date +%-H)

echo "[$(date)] - Memulai Dispatcher. Jam saat ini: ${CURRENT_HOUR}."

# Logika untuk mengarahkan ke script yang sesuai
if (( CURRENT_HOUR < 9 )); then
    # Jika sebelum jam 9 pagi
    echo "   -> Waktu < 09:00. Menjalankan sync presensi rentang 7 hari..."
    ./sync_presensi_range.sh 7
else
    # Jika jam 9 pagi atau setelahnya
    echo "   -> Waktu >= 09:00. Menjalankan sync presensi per kantor..."
    ./sync_presensi_only.sh
fi

echo "[$(date)] - Proses Dispatcher selesai."
echo "----------------------------------------"
