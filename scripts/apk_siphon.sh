#!/usr/bin/env bash
set -euo pipefail

# --- CÁC BIẾN CÓ THỂ TÙY CHỈNH ---
# Thư mục chứa các file .img của phân vùng
OUT_IMG_DIR="${OUT_IMG_DIR:-out_imgs}"
# Thư mục để lưu trữ các file APK được trích xuất
OUT_APK_DIR="${OUT_APK_DIR:-out_apks}"
# Thư mục gốc để mount tạm thời các phân vùng
MOUNT_ROOT="${MOUNT_ROOT:-/mnt/payload_mounts}"

# Tạo các thư mục cần thiết
mkdir -p "$OUT_IMG_DIR" "$OUT_APK_DIR" "$MOUNT_ROOT"

# --- CÁC HÀM HỖ TRỢ ---
is_sparse() {
  # Kiểm tra xem file có phải là Android sparse image không
  file -b "$1" 2>/dev/null | grep -qi "Android sparse image"
}

is_erofs() {
  # Kiểm tra xem file có phải là định dạng EROFS không bằng cách đọc magic number
  [[ "$(hexdump -s 1024 -n 4 -e '1/4 "%08x"' "$1" 2>/dev/null || true)" == "e0f5e1e2" ]]
}

safe_umount() {
  # Unmount một thư mục một cách an toàn
  local mp="$1"
  if mountpoint -q "$mp"; then
    sudo umount "$mp" || true
  fi
}

cleanup() {
  # Dọn dẹp tất cả các mount point khi script kết thúc (dù thành công hay thất bại)
  echo "[*] Cleaning up mount points..."
  for d in "$MOUNT_ROOT"/*; do
    [[ -d "$d" ]] && safe_umount "$d"
  done
}
trap cleanup EXIT

# --- GIAI ĐOẠN 1: CHUẨN HÓA IMAGE ---
echo "[*] Normalize all images (sparse → raw if needed)…"
shopt -s nullglob
for IMG in "$OUT_IMG_DIR"/*.img; do
  if is_sparse "$IMG"; then
    echo "    - $(basename "$IMG") is sparse → simg2img"
    RAW="${IMG%.img}.raw.img"
    simg2img "$IMG" "$RAW"
    mv -f "$RAW" "$IMG"
  fi
done
shopt -u nullglob

# --- GIAI ĐOẠN 2: TRÍCH XUẤT APK ---
echo "[*] Extract APKs from ALL partitions…"
shopt -s nullglob
for IMG in "$OUT_IMG_DIR"/*.img; do
  PART="$(basename "$IMG" .img)"
  echo "--- Processing: [$PART] ---"
  
  DEST_PART_DIR="$OUT_APK_DIR/$PART"
  mkdir -p "$DEST_PART_DIR"

  if is_erofs "$IMG"; then
    echo "    EROFS detected → extract.erofs"
    EXDIR="$MOUNT_ROOT/${PART}_erofs_dump" # Dùng mount root để dump tạm
    mkdir -p "$EXDIR"
    # Giải nén toàn bộ hệ thống file
    extract.erofs -i "$IMG" -x -o "$EXDIR"

    # Dùng một lệnh rsync để quét toàn bộ và chỉ copy APK, giữ nguyên cấu trúc thư mục
    echo "    -> Scanning and copying all APKs from EROFS dump..."
    rsync -a -m --include='**/*.apk' --include='*/' --exclude='*' "$EXDIR/" "$DEST_PART_DIR/"
    
    # Dọn dẹp thư mục dump
    rm -rf "$EXDIR"

  else
    echo "    ext4/raw → mount loop ro"
    MP="$MOUNT_ROOT/$PART"
    mkdir -p "$MP"
    if ! sudo mount -o ro,loop "$IMG" "$MP"; then
      echo "    ! Mount failed, skipping $PART"
      rmdir "$MP" || true
      continue
    fi

    # Dùng một lệnh rsync để quét toàn bộ và chỉ copy APK, giữ nguyên cấu trúc thư mục
    echo "    -> Scanning and copying all APKs from mount point..."
    rsync -a -m --include='**/*.apk' --include='*/' --exclude='*' "$MP/" "$DEST_PART_DIR/"

    safe_umount "$MP"
    rmdir "$MP" || true
  fi
done
shopt -u nullglob

echo "[✓] APKs extracted to: $OUT_APK_DIR"
echo "[✓] Total APKs found: $(find "$OUT_APK_DIR" -type f -name '*.apk' | wc -l)"
