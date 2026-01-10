#!/usr/bin/env bash

# Copyright (c) 2025 Lightmatter, Inc. All Rights Reserved.

# Fetch logs from Kenya systems (BMC or FPGA)
# Usage: fetch_kenya_logs.sh [--bmc|--fpga] [--user <username>] <identifier> [output_directory]
#   identifier: IP address or bench name (e.g., "3.1", "pa-goodnow-1782-bmc-top")
#   output_directory: directory to save logs (defaults to identifier)

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Defaults
TARGET_TYPE="bmc"
FPGA_USER="$USER"

usage() {
    echo "Usage: $0 [--bmc|--fpga] [--user <username>] <identifier> [output_directory]"
    echo ""
    echo "Options:"
    echo "  --bmc             Fetch logs from BMC (default)"
    echo "  --fpga            Fetch logs from FPGA"
    echo "  --user <username> Username for FPGA home directory (default: \$USER)"
    echo ""
    echo "Arguments:"
    echo "  identifier        IP address or bench name (e.g., '3.1', 'pa-goodnow-1782-bmc-top')"
    echo "  output_directory  Directory to save logs (defaults to identifier)"
    echo ""
    echo "Examples:"
    echo "  $0 3.1                        # Fetch BMC logs from bench 3.1 into ./3.1/"
    echo "  $0 --fpga 3.1                 # Fetch FPGA logs from bench 3.1"
    echo "  $0 --fpga --user bob 3.1      # Fetch FPGA logs from bob's directory"
    echo "  $0 10.10.21.221               # Fetch BMC logs from IP into ./10.10.21.221/"
    echo "  $0 3.1 ./my_logs              # Fetch BMC logs from bench 3.1 into ./my_logs/"
    exit 1
}

# Parse command-line options
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bmc)
            TARGET_TYPE="bmc"
            shift
            ;;
        --fpga)
            TARGET_TYPE="fpga"
            shift
            ;;
        --user)
            if [ -z "$2" ] || [[ "$2" == --* ]]; then
                echo -e "${RED}Error: --user requires a username argument${NC}"
                usage
            fi
            FPGA_USER="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            usage
            ;;
        *)
            # First non-option argument is the identifier
            if [ -z "$IDENTIFIER" ]; then
                IDENTIFIER="$1"
            elif [ -z "$OUTPUT_DIR" ]; then
                OUTPUT_DIR="$1"
            else
                echo -e "${RED}Error: Too many arguments${NC}"
                usage
            fi
            shift
            ;;
    esac
done

# Check for required argument
if [ -z "$IDENTIFIER" ]; then
    echo -e "${RED}Error: Identifier required${NC}"
    usage
fi

OUTPUT_DIR="${OUTPUT_DIR:-$IDENTIFIER}"

# Function to check if string is an IP address
is_ip_address() {
    local ip="$1"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    fi
    return 1
}

# Function to get testbed output (cached)
get_testbed_output() {
    # Check if reserve-testbed command exists
    if ! command -v reserve-testbed &> /dev/null; then
        echo -e "${RED}Error: reserve-testbed command not found${NC}" >&2
        echo -e "${YELLOW}Make sure you have lab-automation tools installed and activated${NC}" >&2
        return 1
    fi

    reserve-testbed show 2>/dev/null
}

# Function to look up BMC info from reserve-testbed
lookup_bmc() {
    local identifier="$1"
    local testbed_output

    testbed_output=$(get_testbed_output)
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Try to find the identifier in the output
    # Match either the bench number (e.g., "3.1:") or the name in brackets
    local line
    line=$(echo "$testbed_output" | grep -E "^${identifier}:|\\[${identifier}\\]" | head -1)

    if [ -z "$line" ]; then
        echo -e "${RED}Error: BMC '$identifier' not found in testbed list${NC}" >&2
        return 1
    fi

    echo "$line"
}

# Function to look up FPGA IP from reserve-testbed given a BMC identifier
# The FPGA line is directly below the BMC line and starts with "-"
lookup_fpga() {
    local identifier="$1"
    local testbed_output
    local found_bmc=false
    local fpga_line=""

    testbed_output=$(get_testbed_output)
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Process line by line to find BMC and then the FPGA below it
    while IFS= read -r line; do
        if [ "$found_bmc" = true ]; then
            # Check if this is the FPGA line (starts with -)
            if [[ "$line" =~ ^-.*fpga ]]; then
                fpga_line="$line"
                break
            else
                # Not an FPGA line, BMC doesn't have associated FPGA
                break
            fi
        fi

        # Check if this line matches our BMC identifier
        if echo "$line" | grep -qE "^${identifier}:|\\[${identifier}\\]"; then
            found_bmc=true
        fi
    done <<< "$testbed_output"

    if [ -z "$fpga_line" ]; then
        echo -e "${RED}Error: No FPGA found for '$identifier'${NC}" >&2
        return 1
    fi

    echo "$fpga_line"
}

# Function to extract IP from testbed line
extract_ip() {
    local line="$1"
    # IP address is the third field, extract it
    echo "$line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# Function to check if target is online
is_online() {
    local line="$1"
    if echo "$line" | grep -q "Online"; then
        return 0
    fi
    return 1
}

# Determine the IP address based on target type
if [ "$TARGET_TYPE" = "fpga" ]; then
    SSH_USER="petalinux"
    TARGET_LABEL="FPGA"

    if is_ip_address "$IDENTIFIER"; then
        TARGET_IP="$IDENTIFIER"
        echo -e "${GREEN}Using FPGA IP address: $TARGET_IP${NC}"
    else
        echo "Looking up FPGA for '$IDENTIFIER'..."
        TARGET_LINE=$(lookup_fpga "$IDENTIFIER")
        if [ $? -ne 0 ]; then
            exit 1
        fi

        TARGET_IP=$(extract_ip "$TARGET_LINE")
        if [ -z "$TARGET_IP" ]; then
            echo -e "${RED}Error: Could not extract IP address from testbed entry${NC}"
            exit 1
        fi

        # Check if FPGA is online
        if ! is_online "$TARGET_LINE"; then
            echo -e "${RED}Error: FPGA for '$IDENTIFIER' ($TARGET_IP) is offline${NC}"
            exit 1
        fi

        echo -e "${GREEN}Found FPGA: $IDENTIFIER -> $TARGET_IP (Online)${NC}"
    fi
else
    SSH_USER="root"
    TARGET_LABEL="BMC"

    if is_ip_address "$IDENTIFIER"; then
        TARGET_IP="$IDENTIFIER"
        echo -e "${GREEN}Using BMC IP address: $TARGET_IP${NC}"
    else
        echo "Looking up BMC '$IDENTIFIER'..."
        TARGET_LINE=$(lookup_bmc "$IDENTIFIER")
        if [ $? -ne 0 ]; then
            exit 1
        fi

        TARGET_IP=$(extract_ip "$TARGET_LINE")
        if [ -z "$TARGET_IP" ]; then
            echo -e "${RED}Error: Could not extract IP address from testbed entry${NC}"
            exit 1
        fi

        # Check if BMC is online
        if ! is_online "$TARGET_LINE"; then
            echo -e "${RED}Error: BMC '$IDENTIFIER' ($TARGET_IP) is offline${NC}"
            exit 1
        fi

        echo -e "${GREEN}Found BMC: $IDENTIFIER -> $TARGET_IP (Online)${NC}"
    fi
fi

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Test SSH connection and handle host key issues
echo "Testing SSH connection to $TARGET_IP..."
SSH_TEST_OUTPUT=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$TARGET_IP" echo ok 2>&1) || true

SSH_OK=false
if [ "$SSH_TEST_OUTPUT" = "ok" ]; then
    echo -e "${GREEN}SSH connection successful${NC}"
    SSH_OK=true
elif echo "$SSH_TEST_OUTPUT" | grep -qi "host key"; then
    # Host key mismatch - remove old key and retry
    echo -e "${YELLOW}Host key changed for $TARGET_IP, removing old key...${NC}"
    ssh-keygen -R "$TARGET_IP" 2>/dev/null || true

    # Try again with StrictHostKeyChecking=accept-new to auto-accept the new key
    SSH_TEST_OUTPUT=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$SSH_USER@$TARGET_IP" echo ok 2>&1) || true

    if [ "$SSH_TEST_OUTPUT" = "ok" ]; then
        echo -e "${GREEN}SSH connection successful with new host key${NC}"
        SSH_OK=true
    elif ! echo "$SSH_TEST_OUTPUT" | grep -qi "permission denied"; then
        # Failed for a reason other than permission denied
        echo -e "${RED}SSH connection failed after host key update${NC}"
        echo "$SSH_TEST_OUTPUT"
        exit 1
    fi
    # If permission denied, fall through to the next block
fi

if [ "$SSH_OK" = false ]; then
    if echo "$SSH_TEST_OUTPUT" | grep -qi "permission denied"; then
        # No SSH key set up - offer to copy ID
        echo -e "${YELLOW}SSH key not authorized on $TARGET_LABEL${NC}"
        if [ -t 0 ]; then
            echo -n "Would you like to copy your SSH key to the $TARGET_LABEL? [y/N] "
            read -r REPLY
            if [[ "$REPLY" =~ ^[Yy]$ ]]; then
                echo "Running ssh-copy-id $SSH_USER@$TARGET_IP..."
                ssh-copy-id "$SSH_USER@$TARGET_IP"
            else
                echo -e "${RED}Cannot proceed without SSH access${NC}"
                exit 1
            fi
        else
            echo -e "${RED}Run 'ssh-copy-id $SSH_USER@$TARGET_IP' to set up SSH key access${NC}"
            exit 1
        fi
    else
        echo -e "${RED}SSH connection failed: $SSH_TEST_OUTPUT${NC}"
        exit 1
    fi
fi

# Fetch the logs
if [ "$TARGET_TYPE" = "fpga" ]; then
    FPGA_BASE="/run/media/root-mmcblk0p2/home/$FPGA_USER/congo"
    FPGA_RSYNC="/run/media/root-mmcblk0p2/usr/bin/rsync"

    echo "Checking for log directories on FPGA..."

    # Check which directories exist on the FPGA
    LIB_EXISTS=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$TARGET_IP" "test -d '$FPGA_BASE/lib' && echo yes || echo no")
    LOGS_EXISTS=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$TARGET_IP" "test -d '$FPGA_BASE/logs' && echo yes || echo no")

    if [ "$LIB_EXISTS" = "no" ] && [ "$LOGS_EXISTS" = "no" ]; then
        echo -e "${RED}Error: No log directories found at $FPGA_BASE/${NC}"
        echo -e "${YELLOW}Neither 'lib' nor 'logs' directories exist for user '$FPGA_USER'${NC}"
        # List available users
        echo ""
        echo "Available user directories on FPGA:"
        ssh -o BatchMode=yes "$SSH_USER@$TARGET_IP" "ls -1 /run/media/root-mmcblk0p2/home/ 2>/dev/null" | sed 's/^/  /'
        echo ""
        echo -e "${YELLOW}Hint: Use --user <username> to specify a different user${NC}"
        exit 1
    fi

    echo "Fetching FPGA logs from $SSH_USER@$TARGET_IP..."
    echo "Saving to: $OUTPUT_DIR/"

    FETCHED=0

    # Only fetch .log and .log.gz files
    RSYNC_FILTERS=(--include='*.log' --include='*.log.gz' --exclude='*')

    # Fetch from lib directory if it exists
    if [ "$LIB_EXISTS" = "yes" ]; then
        echo "  Fetching from: $FPGA_BASE/lib/"
        rsync -avz --progress --rsync-path="$FPGA_RSYNC" "${RSYNC_FILTERS[@]}" "$SSH_USER@$TARGET_IP:$FPGA_BASE/lib/" "$OUTPUT_DIR/" && FETCHED=$((FETCHED + 1))
    else
        echo -e "${YELLOW}  Skipping $FPGA_BASE/lib/ (does not exist)${NC}"
    fi

    # Fetch from logs directory if it exists
    if [ "$LOGS_EXISTS" = "yes" ]; then
        echo "  Fetching from: $FPGA_BASE/logs/"
        rsync -avz --progress --rsync-path="$FPGA_RSYNC" "${RSYNC_FILTERS[@]}" "$SSH_USER@$TARGET_IP:$FPGA_BASE/logs/" "$OUTPUT_DIR/" && FETCHED=$((FETCHED + 1))
    else
        echo -e "${YELLOW}  Skipping $FPGA_BASE/logs/ (does not exist)${NC}"
    fi

    if [ "$FETCHED" -eq 0 ]; then
        echo -e "${RED}Error: Failed to fetch logs from any directory${NC}"
        exit 1
    fi
else
    echo "Fetching BMC logs from $SSH_USER@$TARGET_IP:/var/log/validation_server*.log..."
    echo "Saving to: $OUTPUT_DIR/"

    rsync -avz --progress "$SSH_USER@$TARGET_IP:/var/log/validation_server*.log" "$OUTPUT_DIR/"
fi

echo -e "${GREEN}Done! Logs saved to $OUTPUT_DIR/${NC}"
ls -la "$OUTPUT_DIR/"
