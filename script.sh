#!/bin/bash
unsetopt HIST_EXPAND 2>/dev/null || true
set -e

# --- CONFIGURATION (Relative Paths) ---
TMP=$(mktemp -d)
INPUT_DIR="./reels"
AUDIO_DIR="./audio"
LOGO_PATH="./spotify.png"
QUOTES_FILE="./quotes.txt"
OUTPUT_DIR="./output"
FONT="./Inter-Black.ttf"

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# 1. ASSET CHECK
[ ! -f "$LOGO_PATH" ] && echo "❌ spotify.png missing" && exit 1
[ ! -f "$QUOTES_FILE" ] && echo "❌ quotes.txt missing" && exit 1

# Font Logic: Check for local font, then Mac fallback, then Linux/GitHub fallback
if [ ! -f "$FONT" ]; then
    if [ -f "/Library/Fonts/Arial Unicode.ttf" ]; then
        FONT="/Library/Fonts/Arial Unicode.ttf"
    else
        FONT="/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
    fi
fi

# Pick 15 random 1-second clips and 1 random audio file
FILES=($(find "$INPUT_DIR" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mov" \) | sort -R | head -n 15))
AUDIO_FILE=$(find "$AUDIO_DIR" -maxdepth 1 -type f -iname "*.mp3" | sort -R | head -n 1)

if [ ${#FILES[@]} -eq 0 ]; then echo "❌ No videos found in $INPUT_DIR"; exit 1; fi

# 2. STEP 1: PROCESS & MERGE CLIPS (Visuals Only)
echo "🎬 Step 1: Processing Clips..."
i=1
for f in "${FILES[@]}"; do
  ffmpeg -i "$f" -t 1 -vf "scale=1080:1920:force_original_aspect_ratio=decrease,pad=1080:1920:(ow-iw)/2:(oh-ih)/2:black,fps=30" \
    -c:v libx264 -preset superfast -pix_fmt yuv420p -an "$TMP/clip_$i.mp4" -y -loglevel error
  echo "file '$TMP/clip_$i.mp4'" >> "$TMP/list.txt"
  i=$((i+1))
done

MERGED_RAW="$TMP/merged_raw.mp4"
ffmpeg -f concat -safe 0 -i "$TMP/list.txt" -c copy "$MERGED_RAW" -y -loglevel error
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$MERGED_RAW")

# 3. STEP 2: APPLY LOGO AND QUOTE (Bake Visuals)
echo "🎨 Step 2: Applying Visuals (Max Compression)..."
TOTAL=$(wc -l < "$QUOTES_FILE" | xargs)
line=$((RANDOM % TOTAL + 1))

# PERL CLEANING: Specifically removes non-ASCII and hidden control characters
raw=$(sed -n "${line}p" "$QUOTES_FILE" | perl -pe 's/[^[:ascii:]]//g; s/[\x00-\x1f\x7f]//g' | xargs)
echo "$raw" | fold -s -w 45 > "$TMP/quote.txt"

logo_start=$(echo "$DUR" | awk '{print $1 / 2}')
logo_fade=$(echo "$DUR" | awk '{print $1 - 1.2}')

# FILTER: Logo at bottom (y=H-h-120), Quote at top (y=h*0.15), Fontsize=45
FILTER="[1:v]loop=-1:1:0,scale=180:-1,format=rgba,fade=t=in:st=${logo_start}:d=0.5:alpha=1,fade=t=out:st=${logo_fade}:d=0.5:alpha=1[logo_p]; \
[0:v][logo_p]overlay=x=(W-w)/2:y=H-h-120:shortest=1[v_l]; \
[v_l]drawtext=fontfile='${FONT}':textfile='$TMP/quote.txt':fontcolor=white:fontsize=45: \
box=1:boxcolor=black@0.7:boxborderw=20:line_spacing=15:x=(w-text_w)/2:y=(h*0.15):expansion=none[v_f]"

VISUAL_MASTER="$TMP/visual_master.mp4"

# Using -preset veryslow and -crf 24 for smallest file size
ffmpeg -i "$MERGED_RAW" -i "$LOGO_PATH" -filter_complex "$FILTER" \
  -map "[v_f]" -c:v libx264 -preset veryslow -crf 24 -tune stillimage -pix_fmt yuv420p -an "$VISUAL_MASTER" -y -loglevel warning

# 4. STEP 3: FINAL AUDIO GLUE
echo "🎵 Step 3: Adding Audio..."
FADE_VAL=$(echo "$DUR" | awk '{print ($1 > 2) ? $1 - 2 : 0}')
safe_name=$(echo "$raw" | tr -cd '[:alnum:] ' | cut -c1-50 | xargs)
out_file="$OUTPUT_DIR/${safe_name}.mp4"

# capping audio at 128k for further size savings
ffmpeg -i "$VISUAL_MASTER" -i "$AUDIO_FILE" \
  -filter_complex "[1:a]afade=t=out:st=${FADE_VAL}:d=2[aud]" \
  -map 0:v -map "[aud]" -c:v copy -c:a aac -b:a 128k -shortest "$out_file" -y -loglevel warning

echo "✅ SUCCESS! Saved to: $out_file"
# ... (Previous Video Processing Code remains the same) ...

echo "✅ SUCCESS! Saved to: $out_file"

# --- GITHUB RELEASE LOGIC ---
# 1. Create a Unique Tag (using Run ID to match your YAML logic)
TAG_NAME="v-${GITHUB_RUN_ID:-$(date +%s)}"

echo "📦 Creating GitHub Release: $TAG_NAME"

# 2. Create the release and upload the MP4
# --clobber allows overwriting if the tag exists
gh release create "$TAG_NAME" "$out_file" \
    --title "Reel: $safe_name" \
    --notes "Automated upload from GitHub Actions."

# 3. Construct the DIRECT download URL
# Replace YOUR_USER and YOUR_REPO with your actual details
DIRECT_URL="https://github.com/YOUR_USER/YOUR_REPO/releases/download/$TAG_NAME/${safe_name// /_}.mp4"

# 4. SEND TO WEBHOOK
echo "🚀 Sending direct link to webhook..."
WEBHOOK_URL="YOUR_WEBHOOK_URL_HERE"

curl -X POST -H "Content-Type: application/json" \
  -d "{\"content\": \"🎥 **New Reel Generated!**\nDirect MP4 Link: $DIRECT_URL\"}" $WEBHOOK_URL

# 5. AUTO-CLEANUP (The "Retention" Logic)
# This deletes any releases older than 24 hours to save space
echo "🧹 Cleaning up old releases..."
gh release list --limit 50 | while read -r line; do
    # Get tag name and timestamp
    OLD_TAG=$(echo "$line" | awk '{print $1}')
    # If the tag starts with 'v-' and isn't the one we just made
    if [[ "$OLD_TAG" == v-* ]] && [[ "$OLD_TAG" != "$TAG_NAME" ]]; then
        echo "Deleting old release: $OLD_TAG"
        gh release delete "$OLD_TAG" --yes --cleanup-tag
    fi
done

rm -rf "$TMP"
rm -rf "$TMP"
