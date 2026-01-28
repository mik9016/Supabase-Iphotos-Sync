#!/bin/bash

# IPhotos-Sync Quick Reinstall Script
# Just connect your iPhone and run: ./reinstall.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/IPhotos-Sync"
PROJECT_FILE="$PROJECT_DIR/IPhotos-Sync.xcodeproj"
SCHEME="IPhotos-Sync"
BUILD_DIR="$SCRIPT_DIR/build"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo ""
echo "========================================="
echo "  IPhotos-Sync Quick Reinstall"
echo "========================================="
echo ""

# Check if ios-deploy is installed
if ! command -v ios-deploy &> /dev/null; then
    echo -e "${RED}Error: ios-deploy is not installed${NC}"
    echo ""
    echo "Install it with:"
    echo "  brew install ios-deploy"
    echo ""
    exit 1
fi

# Check if Xcode command line tools are available
if ! command -v xcodebuild &> /dev/null; then
    echo -e "${RED}Error: Xcode command line tools not found${NC}"
    echo ""
    echo "Install with:"
    echo "  xcode-select --install"
    echo ""
    exit 1
fi

# Check if project exists
if [ ! -d "$PROJECT_FILE" ]; then
    echo -e "${RED}Error: Project not found at $PROJECT_FILE${NC}"
    exit 1
fi

# Check if Secrets.swift exists
if [ ! -f "$PROJECT_DIR/IPhotos-Sync/Secrets.swift" ]; then
    echo -e "${RED}Error: Secrets.swift not found${NC}"
    echo ""
    echo "Create it from the template:"
    echo "  cp IPhotos-Sync/IPhotos-Sync/Secrets.swift.template IPhotos-Sync/IPhotos-Sync/Secrets.swift"
    echo "  # Then edit with your Supabase credentials"
    echo ""
    exit 1
fi

# Check for connected device
echo -e "${YELLOW}Checking for connected iPhone...${NC}"
DEVICE_ID=$(ios-deploy -c 2>/dev/null | grep -o '\[[a-f0-9]*\]' | tr -d '[]' | head -1)

if [ -z "$DEVICE_ID" ]; then
    echo -e "${RED}No iPhone detected!${NC}"
    echo ""
    echo "Please:"
    echo "  1. Connect your iPhone via USB"
    echo "  2. Unlock your iPhone"
    echo "  3. Trust this computer if prompted"
    echo "  4. Run this script again"
    echo ""
    exit 1
fi

echo -e "${GREEN}Found device: $DEVICE_ID${NC}"
echo ""

# Build the app
echo -e "${YELLOW}Building app (this may take a minute)...${NC}"
echo ""

xcodebuild \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "id=$DEVICE_ID" \
    -derivedDataPath "$BUILD_DIR" \
    -allowProvisioningUpdates \
    build \
    2>&1 | grep -E "(Build Succeeded|error:|warning:.*error)" || true

# Find the built app
APP_PATH=$(find "$BUILD_DIR" -name "*.app" -type d | head -1)

if [ -z "$APP_PATH" ]; then
    echo -e "${RED}Build failed! App not found.${NC}"
    echo ""
    echo "Try building manually in Xcode first to fix any signing issues."
    exit 1
fi

echo ""
echo -e "${GREEN}Build succeeded!${NC}"
echo ""

# Install on device
echo -e "${YELLOW}Installing on iPhone...${NC}"
echo ""

ios-deploy --bundle "$APP_PATH" --id "$DEVICE_ID"

echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}  Done! App installed successfully.${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo "The app is now on your iPhone and will work for 7 days."
echo "Run this script again when it expires."
echo ""
