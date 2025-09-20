#!/usr/bin/env bash
set -euo pipefail

OUT_IMG_DIR="out_imgs"
OUT_APK_DIR="out_apks"
MOUNT_ROOT="/mnt/payload_mounts"
APK_SUBDIRS=("app" "priv-app")

# Define the list of partitions to process
CANDIDATE_PARTS=(
    "my_bigball"
    "my_carrier"
    "my_engineering"
    "my_heytap"
    "my_manifest"
    "my_product"
    "my_region"
    "my_company"
    "my_stock"
    "my_preload"
    "odm"
    "product"
    "system"
    "system_ext"
    "vendor"
)

# Helper functions
is_sparse() { file -b "$1" 2>/dev/null | grep -qi "Android sparse image"; }
is_erofs() { [[ "$(hexdump -s 1024 -n 4 -e '1/4 "%08x"' "$1" 2>/dev/null || true)" == "e0f5e1e2" ]]; }
safe_umount() { if mountpoint -q "$1"; then sudo umount "$1" || true; fi; }
cleanup() { for d in "$MOUNT_ROOT"/*; do [[ -d "$d" ]] && safe_umount "$d"; done; }
trap cleanup EXIT

# First, convert any sparse images to raw images
echo "[*] Normalizing sparse images to raw..."
shopt -s nullglob
for IMG in "$OUT_IMG_DIR"/*.img; do
  if is_sparse "$IMG"; then
    echo "    -> Converting $(basename "$IMG")"
    RAW="${IMG%.img}.raw.img"
    simg2img "$IMG" "$RAW" && mv -f "$RAW" "$IMG"
  fi
done
shopt -u nullglob

# Create a fast lookup map for candidate partitions
declare -A a_want_part=()
for p in "${CANDIDATE_PARTS[@]}"; do a_want_part["$p"]=1; done

# Process all dumped .img files
echo "[*] Starting APK extraction from partitions..."
shopt -s nullglob
for IMG in "$OUT_IMG_DIR"/*.img; do
  PART="$(basename "$IMG" .img)"
  
  # Skip if the partition is not in our candidate list
  [[ -v a_want_part[$PART] ]] || { echo "--- Skipping: [$PART] (not in extraction list) ---"; continue; }

  echo "--- Processing: [$PART] ---"
  DEST_PART_DIR="$OUT_APK_DIR/$PART"

  scan_and_copy_apks() {
    local search_root="$1"
    for SUBDIR in "${APK_SUBDIRS[@]}"; do
      find "$search_root" -type d -name "$SUBDIR" -print0 2>/dev/null | while IFS= read -r -d '' SRC_DIR; do
        if [ -d "$SRC_DIR" ]; then
          REL_PATH=$(realpath --relative-to="$search_root" "$SRC_DIR")
          DEST_DIR="$DEST_PART_DIR/$REL_PATH"
          mkdir -p "$DEST_DIR"
          rsync -a --include="*.apk" --exclude="*" "$SRC_DIR/" "$DEST_DIR/"
        fi
      done
    done
  }

  if is_erofs "$IMG"; then
    echo "    -> EROFS detected."
    if command -v extract.erofs &> /dev/null; then
        echo "    -> Using 'extract.erofs'..."
        EXDIR="$MOUNT_ROOT/${PART}_erofs_dump"; mkdir -p "$EXDIR"
        extract.erofs -i "$IMG" -x -o "$EXDIR"; scan_and_copy_apks "$EXDIR"; rm -rf "$EXDIR"
    elif command -v erofsfuse &> /dev/null; then
        echo "    -> 'extract.erofs' not found. Falling back to 'erofsfuse'..."
        MP="$MOUNT_ROOT/$PART"; mkdir -p "$MP"
        erofsfuse "$IMG" "$MP"; scan_and_copy_apks "$MP"; safe_umount "$MP"; rmdir "$MP" || true
    else
        echo "    -> FATAL: Neither 'extract.erofs' nor 'erofsfuse' found." >&2
        exit 1
    fi
  else
    echo "    -> ext4/raw detected."
    MP="$MOUNT_ROOT/$PART"; mkdir -p "$MP"
    if ! sudo mount -o ro,loop "$IMG" "$MP"; then
      echo "    -> Mount failed for $PART, skipping."
      rmdir "$MP" || true
      continue
    fi
    scan_and_copy_apks "$MP"
    safe_umount "$MP"
    rmdir "$MP" || true
  fi
done
shopt -u nullglob

echo "[✓] APK extraction process finished."
