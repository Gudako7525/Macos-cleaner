#!/usr/bin/env bash
# ==============================================================================
# verify_cleaner.sh
# Production Pre-Flight & Diagnostics Verifier for SystemCleaner (macOS 14/15 ARM64)
# ==============================================================================
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

APP_PATH="${1:-build/Release/SystemCleaner.app}"
HELPER_LABEL="com.cleaner.helper"
HELPER_PATH="$APP_PATH/Contents/Library/LaunchDaemons/$HELPER_LABEL"
HELPER_PLIST="$APP_PATH/Contents/Library/LaunchDaemons/$HELPER_LABEL.plist"
MAIN_BIN="$APP_PATH/Contents/MacOS/SystemCleaner"

FAILED_CHECKS=0

pass() { echo -e "  [${GREEN}PASS${NC}] $1"; }
fail() { echo -e "  [${RED}FAIL${NC}] $1"; ((FAILED_CHECKS++)); }
warn() { echo -e "  [${YELLOW}WARN${NC}] $1"; }
header() { echo -e "\n${BLUE}==> $1${NC}"; }

echo -e "Starting SystemCleaner Production Diagnostic Suite..."
echo -e "Target Bundle: $APP_PATH"

# ------------------------------------------------------------------------------
# Check 1: Bundle Topology & SMAppService Requirements
# ------------------------------------------------------------------------------
header "1. Validating Bundle Structure & SMAppService Placement"

if [ -d "$APP_PATH" ]; then
    pass "Main app bundle exists at $APP_PATH"
else
    fail "App bundle not found at $APP_PATH. Build the project first."
    exit 1
fi

if [ -f "$MAIN_BIN" ]; then
    pass "Main Mach-O executable exists."
else
    fail "Missing main binary: $MAIN_BIN"
fi

if [ -f "$HELPER_PATH" ]; then
    pass "Privileged helper binary placed in Contents/Library/LaunchDaemons/"
else
    fail "Helper missing from Contents/Library/LaunchDaemons/. SMAppService requires this exact location."
fi

if [ -f "$HELPER_PLIST" ]; then
    pass "Helper launchd plist found in Contents/Library/LaunchDaemons/"
    if grep -q "<key>MachServices</key>" "$HELPER_PLIST"; then
        pass "Helper plist declares <key>MachServices</key>"
    else
        fail "Helper plist is missing <key>MachServices</key> dictionary."
    fi
else
    fail "Helper launchd plist missing: $HELPER_PLIST"
fi

# ------------------------------------------------------------------------------
# Check 2: Apple Silicon Architecture Slice (lipo)
# ------------------------------------------------------------------------------
header "2. Validating Binary Architecture Slices (ARM64)"

check_arch() {
    local target="$1"
    local name="$2"
    local archs
    archs=$(lipo -archs "$target" 2>/dev/null || echo "error")
    
    if [[ "$archs" == *"arm64"* ]]; then
        pass "$name contains native Apple Silicon arm64 slice (Found: $archs)"
    else
        fail "$name does NOT contain arm64 slice (Found: $archs)"
    fi
}

check_arch "$MAIN_BIN" "Main Application Binary"
check_arch "$HELPER_PATH" "Privileged Helper Binary"

# ------------------------------------------------------------------------------
# Check 3: Code Signing & Hardened Runtime Checks
# ------------------------------------------------------------------------------
header "3. Code Signing & Hardened Runtime Verification"

verify_signing() {
    local target="$1"
    local name="$2"
    
    if codesign --verify --deep --strict --verbose=2 "$target" 2>&1 | grep -q "valid on disk"; then
        pass "$name has valid cryptographic signature and seal"
    else
        fail "$name failed codesign signature validation"
    fi
    
    local cs_details
    cs_details=$(codesign -dvvv "$target" 2>&1)
    if echo "$cs_details" | grep -q "flags=0x10000(runtime)"; then
        pass "$name is signed with Hardened Runtime enabled"
    else
        fail "$name is missing Hardened Runtime (--options runtime)"
    fi
}

verify_signing "$MAIN_BIN" "Main Application"
verify_signing "$HELPER_PATH" "Privileged Helper"

# ------------------------------------------------------------------------------
# Check 4: Entitlements Isolation Audit
# ------------------------------------------------------------------------------
header "4. Entitlement Isolation Audit"

HELPER_ENTITLEMENTS=$(codesign -d --entitlements :- "$HELPER_PATH" 2>/dev/null || echo "")
if echo "$HELPER_ENTITLEMENTS" | grep -q "com.apple.security.app-sandbox"; then
    fail "Privileged Helper has 'com.apple.security.app-sandbox' enabled. Root operations will be restricted by sandbox kernel hooks!"
else
    pass "Privileged Helper correctly omits App Sandbox"
fi

if echo "$HELPER_ENTITLEMENTS" | grep -q "<key>com.apple.security.get-task-allow</key>[[:space:]]*<true/>"; then
    fail "Privileged Helper has 'get-task-allow' enabled. Must be false for release builds."
else
    pass "Privileged Helper correctly disables 'get-task-allow'"
fi

# ------------------------------------------------------------------------------
# Check 5: Live launchd Registration (Optional)
# ------------------------------------------------------------------------------
header "5. Checking launchd Subsystem Registration"

if launchctl print "system/$HELPER_LABEL" &>/dev/null; then
    pass "Helper daemon is currently active and registered in launchd system domain."
else
    warn "Helper daemon is not currently registered in launchd system domain."
    echo "         (Expected if SMAppService.register() has not yet been executed from the app)."
fi

# ------------------------------------------------------------------------------
# Final Assessment
# ------------------------------------------------------------------------------
echo -e "\n=============================================================================="
if [ "$FAILED_CHECKS" -eq 0 ]; then
    echo -e "${GREEN}ALL PRE-FLIGHT DIAGNOSTICS PASSED!${NC} Bundle is ready for Notarization."
    exit 0
else
    echo -e "${RED}DIAGNOSTICS FAILED: $FAILED_CHECKS check(s) did not meet requirements.${NC}"
    exit 1
fi
