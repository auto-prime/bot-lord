#!/usr/bin/env bash
set -euo pipefail

OUT_IMG_DIR="${OUT_IMG_DIR:-out_imgs}"
OUT_APK_DIR="${OUT_APK_DIR:-out_apks}"
MOUNT_ROOT="${MOUNT_ROOT:-/mnt/payload_mounts}"
APK_DIRS=("system/app" "system/priv-app" "product/app" "system_ext/app" "vendor/app" "odm/app" "oem/app")

mkdir -p "$OUT_IMG_DIR" "$OUT_APK_DIR" "$MOUNT_ROOT"

is_sparse() {
  file -b "$1" 2>/dev/null | grep -qi "Android sparse image"
}

is_erofs() {
  # magic EROFS ở offset 0x400 = 1024 bytes → e0 f5 e1 e2 (little endian in hex print)
  [[ "$(hexdump -s 1024 -n 4 -e '1/4 "%08x"' "$1" 2>/dev/null || true)" == "e0f5e1e2" ]]
}

safe_umount() {
  local mp="$1"
  if mountpoint -q "$mp"; then
    sudo umount "$mp" || true
  fi
}

cleanup() {
  for d in "$MOUNT_ROOT"/*; do
    [[ -d "$d" ]] && safe_umount "$d"
  done
}
trap cleanup EXIT

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

echo "[*] Extract APKs per partition…"
shopt -s nullglob
for IMG in "$OUT_IMG_DIR"/*.img; do
  PART="$(basename "$IMG" .img)"
  echo "--- [$PART] ---"

  if is_erofs "$IMG"; then
    echo "    EROFS detected → extract.erofs"
    EXDIR="$OUT_APK_DIR/$PART/_fs"
    mkdir -p "$EXDIR"
    # Giải toàn bộ, sau đó copy APK giữ nguyên cấu trúc
    extract.erofs -i "$IMG" -x -o "$EXDIR"

    for d in "${APK_DIRS[@]}"; do
      SRC="$EXDIR/$d"
      [[ -d "$SRC" ]] || continue
      DEST="$OUT_APK_DIR/$PART/$d"
      mkdir -p "$DEST"
      rsync -a --include="*/" --include="*.apk" --exclude="*" "$SRC/" "$DEST/"
    done

    # Tuỳ chọn: tiết kiệm dung lượng, xoá dump FS thô
    rm -rf "$EXDIR"

  else
    echo "    ext4/raw → mount loop ro"
    MP="$MOUNT_ROOT/$PART"
    mkdir -p "$MP"
    if ! sudo mount -o ro,loop "$IMG" "$MP"; then
      echo "    ! Mount failed, skip $PART"
      rmdir "$MP" || true
      continue
    fi

    for d in "${APK_DIRS[@]}"; do
      SRC="$MP/$d"
      [[ -d "$SRC" ]] || continue
      DEST="$OUT_APK_DIR/$PART/$d"
      mkdir -p "$DEST"
      rsync -a --include="*/" --include="*.apk" --exclude="*" "$SRC/" "$DEST/"
    done

    safe_umount "$MP"
    rmdir "$MP" || true
  fi
done
shopt -u nullglob

echo "[✓] APKs extracted to: $OUT_APK_DIR"
