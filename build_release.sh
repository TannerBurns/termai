#!/usr/bin/env bash
#
# build_release.sh - Build, sign, and notarize for distribution
#
# Required environment variables:
#   DEVELOPER_ID  - e.g., "Developer ID Application: Your Name (TEAMID)"
#   APPLE_ID      - Your Apple ID email
#   TEAM_ID       - Your 10-character Team ID  
#   APP_PASSWORD  - App-specific password from appleid.apple.com
#
# Usage:
#   ./build_release.sh
#
# For local signed builds without notarization:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./build_package.sh
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo "=========================================="
echo "  TermAI Release Build"
echo "=========================================="
echo

# Check required environment variables
missing_vars=()

if [[ -z "${DEVELOPER_ID:-}" ]]; then
    missing_vars+=("DEVELOPER_ID")
fi
if [[ -z "${APPLE_ID:-}" ]]; then
    missing_vars+=("APPLE_ID")
fi
if [[ -z "${TEAM_ID:-}" ]]; then
    missing_vars+=("TEAM_ID")
fi
if [[ -z "${APP_PASSWORD:-}" ]]; then
    missing_vars+=("APP_PASSWORD")
fi

if [[ ${#missing_vars[@]} -gt 0 ]]; then
    echo -e "${RED}Error: Missing required environment variables:${NC}"
    for var in "${missing_vars[@]}"; do
        echo "  - $var"
    done
    echo
    echo "Set them before running:"
    echo "  export DEVELOPER_ID=\"Developer ID Application: Your Name (TEAMID)\""
    echo "  export APPLE_ID=\"your@email.com\""
    echo "  export TEAM_ID=\"ABCDE12345\""
    echo "  export APP_PASSWORD=\"xxxx-xxxx-xxxx-xxxx\""
    echo
    echo "Or use build_package.sh for local ad-hoc builds without signing."
    exit 1
fi

echo -e "${GREEN}✓ All credentials found${NC}"
echo "  Developer ID: ${DEVELOPER_ID:0:40}..."
echo "  Apple ID: $APPLE_ID"
echo "  Team ID: $TEAM_ID"
echo

# Run the main build script (which will use the env vars)
exec "$(dirname "$0")/build_package.sh"

