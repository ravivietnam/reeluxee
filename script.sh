#!/bin/bash
# Set environment for clean execution
unsetopt HIST_EXPAND 2>/dev/null || true
set -e

# --- 1. CONFIGURATION ---
TMP=$(mktemp -d)
INPUT_DIR="./reels"
AUDIO_DIR="./audio"
LOGO_PATH="./spotify.png"
QUOTES_FILE="./quotes.txt"
OUTPUT_DIR="./output"
FONT="./Inter-Black.ttf"

mkdir -p "$OUTPUT_DIR"

# Asset Check
[ ! -f "$LOGO_PATH" ] && echo "❌ spotify.png missing" && exit 1
[ ! -f "$QUOTES_FILE" ] && echo "❌ quotes.txt missing" && exit 1

# Font Fallback
if [ ! -f "$FONT" ]; then
    if [ -f "/Library/Fonts/Arial Unicode.ttf" ]; then
        FONT="/Library/Fonts/Arial Unicode.ttf"
    else
        FONT="/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
    fi
fi

# Pick assets
FILES=($(find "$INPUT_DIR" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mov" \) | sort -R | head -n 15))
AUDIO_FILE=$(find "$AUDIO_DIR" -maxdepth 1 -type f -iname "*.mp3" | sort -R | head -n 1)

if [ ${#FILES[@]} -eq 0 ]; then echo "❌ No videos found in $INPUT_DIR"; exit 1; fi

# --- 2. MERGE CLIPS ---
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

# --- 3. APPLY LOGO & QUOTE ---
echo "🎨 Step 2: Applying Visuals..."
TOTAL=$(wc -l < "$QUOTES_FILE" | xargs)
line=$((RANDOM % TOTAL + 1))
raw=$(sed -n "${line}p" "$QUOTES_FILE" | perl -pe 's/[^[:ascii:]]//g; s/[\x00-\x1f\x7f]//g' | xargs)
echo "$raw" | fold -s -w 45 > "$TMP/quote.txt"

logo_start=$(echo "$DUR" | awk '{print $1 / 2}')
logo_fade=$(echo "$DUR" | awk '{print $1 - 1.2}')

FILTER="[1:v]loop=-1:1:0,scale=180:-1,format=rgba,fade=t=in:st=${logo_start}:d=0.5:alpha=1,fade=t=out:st=${logo_fade}:d=0.5:alpha=1[logo_p]; \
[0:v][logo_p]overlay=x=(W-w)/2:y=H-h-120:shortest=1[v_l]; \
[v_l]drawtext=fontfile='${FONT}':textfile='$TMP/quote.txt':fontcolor=white:fontsize=35: \
box=1:boxcolor=black@0.7:boxborderw=20:line_spacing=15:x=(w-text_w)/2:y=(h*0.15):expansion=none[v_f]"

VISUAL_MASTER="$TMP/visual_master.mp4"
ffmpeg -i "$MERGED_RAW" -i "$LOGO_PATH" -filter_complex "$FILTER" \
  -map "[v_f]" -c:v libx264 -preset veryslow -crf 24 -tune stillimage -pix_fmt yuv420p -an "$VISUAL_MASTER" -y -loglevel warning

# --- 4. FINAL AUDIO & RENAMING ---
echo "🎵 Step 3: Adding Audio..."
FADE_VAL=$(echo "$DUR" | awk '{print ($1 > 2) ? $1 - 2 : 0}')
safe_name=$(echo "$raw" | tr -cd '[:alnum:] ' | cut -c1-50 | xargs)

if [ -z "$safe_name" ] || [ "$safe_name" = " " ]; then
    safe_name="Reel_$(date +%s)"
fi

url_filename="${safe_name// /_}.mp4"
out_file="$OUTPUT_DIR/$url_filename"

ffmpeg -i "$VISUAL_MASTER" -i "$AUDIO_FILE" \
  -filter_complex "[1:a]afade=t=out:st=${FADE_VAL}:d=2[aud]" \
  -map 0:v -map "[aud]" -c:v copy -c:a aac -b:a 128k -shortest \
  -movflags +faststart "$out_file" -y -loglevel warning

# --- 5. GITHUB RELEASE & SHEETDB LOGGING ---
if [ -n "$GH_TOKEN" ]; then
    echo "📦 Creating GitHub Release..."
    TAG_NAME="v-${GITHUB_RUN_ID:-$(date +%s)}"
    gh release create "$TAG_NAME" "$out_file" --title "Reel: $safe_name"
    
    GHT_URL="https://github.com/${GITHUB_REPOSITORY}/releases/download/$TAG_NAME/$url_filename"
    
    # Check for SheetDB Secret
    if [ -n "$SHEETDB_URL" ]; then
        echo "📊 Logging to Google Sheets via SheetDB..."
        
        # Get IST Time (UTC+5:30)
        CUR_DATE=$(date -d "+5 hours 30 minutes" +%Y-%m-%d)
        CUR_TIME=$(date -d "+5 hours 30 minutes" +%H:%M:%S)

        curl -X POST "$SHEETDB_URL" \
          -H "Content-Type: application/json" \
          -d "{\"data\": [{\"url\": \"$GHT_URL\", \"title\": \"$safe_name\", \"date\": \"$CUR_DATE\", \"time\": \"$CUR_TIME\"}]}"
    else
        echo "⚠️ SHEETDB_URL not found. Skipping Google Sheets log."
    fi
    
    echo "🧹 Cleaning up old releases..."
    OLD_RELEASES=$(gh release list --limit 20 --json tagName --jq '.[].tagName' | grep "v-" | grep -v "$TAG_NAME") || true
    for old_tag in $OLD_RELEASES; do
        gh release delete "$old_tag" --yes --cleanup-tag || true
    done
fi

echo "✅ SUCCESS!"
rm -rf "$TMP"
