#!/usr/bin/env bash
set -euo pipefail

MODEL_VARIANT="${1:-openai_whisper-large-v3_turbo}"
MODEL_TAG="${2:-model-v1}"
HF_REPO="argmaxinc/whisperkit-coreml"
BASE_URL="https://huggingface.co/${HF_REPO}/resolve/main/${MODEL_VARIANT}"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

MODEL_DIR="${WORK_DIR}/model/${MODEL_VARIANT}"
UPLOAD_DIR="${WORK_DIR}/upload"
mkdir -p "$MODEL_DIR" "$UPLOAD_DIR"

# --- Discover files from HF API ---
echo "==> Listing model files from Hugging Face..."

list_files() {
    local dir_path="$1"
    local api_url="https://huggingface.co/api/models/${HF_REPO}/tree/main/${dir_path}"
    local entries
    entries=$(curl -sL "$api_url")

    echo "$entries" | python3 -c "
import json, sys
entries = json.loads(sys.stdin.read())
for e in entries:
    if e['type'] == 'file':
        print('FILE ' + e['path'])
    elif e['type'] == 'directory':
        print('DIR ' + e['path'])
"
}

# Collect all file paths recursively
ALL_FILES=()
DIRS_TO_SCAN=("${MODEL_VARIANT}")

while [ ${#DIRS_TO_SCAN[@]} -gt 0 ]; do
    CURRENT_DIR="${DIRS_TO_SCAN[0]}"
    DIRS_TO_SCAN=("${DIRS_TO_SCAN[@]:1}")

    while IFS= read -r line; do
        TYPE="${line%% *}"
        PATH_VAL="${line#* }"
        if [ "$TYPE" = "FILE" ]; then
            ALL_FILES+=("$PATH_VAL")
        elif [ "$TYPE" = "DIR" ]; then
            DIRS_TO_SCAN+=("$PATH_VAL")
        fi
    done < <(list_files "$CURRENT_DIR")
done

echo "==> Found ${#ALL_FILES[@]} files to download"

# --- Download all files ---
echo "==> Downloading model files..."
for file_path in "${ALL_FILES[@]}"; do
    REL_PATH="${file_path#"${MODEL_VARIANT}"/}"
    DEST="${MODEL_DIR}/${REL_PATH}"
    mkdir -p "$(dirname "$DEST")"

    echo "  Downloading ${REL_PATH}..."
    curl -sL "https://huggingface.co/${HF_REPO}/resolve/main/${file_path}" -o "$DEST"
done

# --- Generate manifest and flatten ---
echo "==> Generating manifest and flattening files..."
MANIFEST="${UPLOAD_DIR}/model-manifest.json"

python3 - "$MODEL_DIR" "$UPLOAD_DIR" "$MODEL_TAG" "$MODEL_VARIANT" << 'PYTHON_EOF'
import json, hashlib, os, shutil, sys

model_dir = sys.argv[1]
upload_dir = sys.argv[2]
model_tag = sys.argv[3]
model_variant = sys.argv[4]

files = []
for root, dirs, filenames in os.walk(model_dir):
    for fname in sorted(filenames):
        filepath = os.path.join(root, fname)
        rel_path = os.path.relpath(filepath, model_dir)
        asset_name = rel_path.replace(os.sep, "--")
        size = os.path.getsize(filepath)

        sha256 = hashlib.sha256()
        with open(filepath, "rb") as f:
            while chunk := f.read(8192):
                sha256.update(chunk)

        files.append({
            "relativePath": rel_path,
            "assetName": asset_name,
            "size": size,
            "sha256": sha256.hexdigest()
        })

        # Copy with flattened name
        shutil.copy2(filepath, os.path.join(upload_dir, asset_name))
        print(f"  {rel_path} ({size:,} bytes)")

manifest = {
    "version": model_tag,
    "variant": model_variant,
    "files": files
}

manifest_path = os.path.join(upload_dir, "model-manifest.json")
with open(manifest_path, "w") as f:
    json.dump(manifest, f, indent=2)

total = sum(f["size"] for f in files)
print(f"\n  Total: {total:,} bytes ({total / 1024 / 1024:.1f} MB)")
print(f"  Files: {len(files)}")
PYTHON_EOF

# --- Upload to GitHub Releases ---
echo "==> Creating GitHub Release '${MODEL_TAG}'..."

# Delete existing release if it exists (for re-runs)
gh release delete "$MODEL_TAG" --yes 2>/dev/null || true

gh release create "$MODEL_TAG" "${UPLOAD_DIR}"/* \
    --title "Model ${MODEL_TAG} (${MODEL_VARIANT})" \
    --notes "WhisperKit CoreML model: ${MODEL_VARIANT}"

echo "==> Done. Model uploaded as ${MODEL_TAG}"
