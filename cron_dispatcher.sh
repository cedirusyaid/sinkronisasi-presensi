#!/bin/bash

# ========================================================================
# Script Pemandu (Dispatcher) untuk Cron Job Presensi
# ========================================================================

# Pindah ke direktori tempat script ini berada.
# Ini PENTING agar script lain dan file .env dapat ditemukan.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "$SCRIPT_DIR"

# --- PENGECEKAN HARI AKHIR PEKAN (WEEKEND) ---
# Dapatkan hari saat ini dalam format angka (1=Senin, ..., 6=Sabtu, 7=Minggu)
DAY_OF_WEEK=$(date +%u)

echo "[$(date)] - Memulai Dispatcher."

# Jika hari ini adalah Sabtu (angka 6) ATAU Minggu (angka 7), hentikan script.
if (( DAY_OF_WEEK == 6 || DAY_OF_WEEK == 7 )); then
    echo "   -> Hari ini akhir pekan. Sinkronisasi dilewati."
    echo "[$(date)] - Proses Dispatcher selesai (dilewati)."
    echo "----------------------------------------"
    exit 0 # Keluar dari script dengan status sukses
fi
# --- AKHIR PENGECEKAN HARI ---


# Dapatkan jam saat ini dalam format 24 jam (tanpa nol di depan)
CURRENT_HOUR=$(date +%-H)

echo "   -> Jam saat ini: ${CURRENT_HOUR}."

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
