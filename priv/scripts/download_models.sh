#!/bin/sh
# Auto-download models for llama.cpp on first run.
# Place GGUF files in /models volume if not already present.
#
# Models:
#   - qwen2.5-0.5b-q4_k_m.gguf  (completion, ~350MB)
#   - bge-m3-q8.gguf (embedding, ~600MB) - user must provide their own BGE-M3 GGUF
#
# Note: BGE-M3 is not auto-downloaded. Place bge-m3-q8.gguf in ./models/
# or use: ./build/bin/llama-server -hf gpustack/bge-m3-GGUF:Q8_0

set -e

MODELS_DIR="/models"

download() {
  local file="$1"
  local url="$2"
  
  if [ ! -f "${MODELS_DIR}/${file}" ]; then
    echo "Downloading ${file}..."
    wget -q --show-progress -O "${MODELS_DIR}/${file}" "$url"
    echo "Done: ${file}"
  else
    echo "Already exists: ${file}"
  fi
}

# Create models directory if missing
mkdir -p "$MODELS_DIR"

# Qwen 2.5 0.6B Q4_K_M (small, fast, good for hackathon)
download "qwen2.5-0.5b-q4_k_m.gguf" \
  "https://huggingface.co/Qwen/Qwen2.5-0.5B-GGUF/resolve/main/qwen2.5-0.5b-q4_k_m.gguf"

# BGE-M3 Q8 (embedding model) - user must provide their own
# See: https://huggingface.co/gpustack/bge-m3-GGUF or use your own converted model
# If you need auto-download, uncomment and add the URL:
# download "bge-m3-q8.gguf" \
#   "YOUR_BGE_M3_GGUF_URL_HERE"

echo "All models ready."