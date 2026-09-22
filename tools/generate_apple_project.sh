#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
icon_dir="$repo_root/App/Assets.xcassets/AppIcon.appiconset"
master="$icon_dir/app-store-1024.png"

mkdir -p "$icon_dir"
swift "$repo_root/tools/render_app_icon.swift" "$master"

while IFS=' ' read -r pixels filename; do
  /usr/bin/sips -z "$pixels" "$pixels" "$master" --out "$icon_dir/$filename" >/dev/null
done <<'SIZES'
40 ios-20@2x.png
60 ios-20@3x.png
58 ios-29@2x.png
87 ios-29@3x.png
80 ios-40@2x.png
120 ios-40@3x.png
120 ios-60@2x.png
180 ios-60@3x.png
20 ipad-20.png
40 ipad-20@2x.png
29 ipad-29.png
58 ipad-29@2x.png
40 ipad-40.png
80 ipad-40@2x.png
76 ipad-76.png
152 ipad-76@2x.png
167 ipad-83.5@2x.png
16 mac-16.png
32 mac-16@2x.png
32 mac-32.png
64 mac-32@2x.png
128 mac-128.png
256 mac-128@2x.png
256 mac-256.png
512 mac-256@2x.png
512 mac-512.png
1024 mac-512@2x.png
SIZES

cd "$repo_root"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required (brew install xcodegen)" >&2
  exit 69
fi
python3 tools/generate_storekit_test_plan.py \
  --output BankReconciliationStoreKit.xctestplan
xcodegen generate --spec project.yml
python3 tools/generate_storekit_test_plan.py \
  --project BankReconciliation.xcodeproj/project.pbxproj \
  --output BankReconciliationStoreKit.xctestplan
