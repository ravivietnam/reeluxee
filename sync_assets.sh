#!/bin/bash
set -e

# --- CONFIGURATION ---
# List the folders you want to sync, separated by spaces
# Example: SYNC_FOLDERS="audio Reels Assets"
SYNC_FOLDERS="audio" 

echo "🔐 Setting up Private Smart Sync for specific folders..."

# 1. Install Rclone
sudo apt-get install rclone -y --quiet

# 2. Authenticate the Bot
mkdir -p ~/.config/rclone
echo "$GDRIVE_SERVICE_ACCOUNT" > ~/.config/rclone/service_account.json

cat <<EOF > ~/.config/rclone/rclone.conf
[private_drive]
type = drive
service_account_file = ~/.config/rclone/service_account.json
scope = drive.readonly
EOF

# 3. Loop through and Sync Folders
if [ -n "$GDRIVE_FOLDER_ID" ]; then
    for FOLDER in $SYNC_FOLDERS; do
        echo "🔄 Mirroring Folder: $FOLDER..."
        
        # Ensure the local folder exists in GitHub workspace
        mkdir -p "./$FOLDER"

        # Sync from Drive subfolder to local subfolder
        rclone copy "private_drive:$FOLDER" "./$FOLDER" \
            --drive-root-folder-id "$GDRIVE_FOLDER_ID" \
            --checksum \
            --verbose \
            --transfers 4
    done
else
    echo "❌ ERROR: GDRIVE_FOLDER_ID missing" && exit 1
fi

# 4. Optional: Cleanup Key (Security)
rm ~/.config/rclone/service_account.json

echo "✅ Specific folder sync complete."
