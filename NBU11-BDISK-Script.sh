#!/bin/bash

# NetBackup 11 - Create a BasicDisk storage unit
# Run as root or as a NetBackup admin user on the NetBackup server.

# ===== User variables =====
STU_NAME="BasicDisk_STU_01"
STU_PATH="/backup/basicdisk01"
MEDIA_SERVER="nbu-media01"
MAX_JOBS="4"
HIGH_WATER_MARK="98"
LOW_WATER_MARK="80"
ON_DEMAND_ONLY="1"
OK_ON_ROOT="0"

# ===== NetBackup command path =====
BPSTUADD="/usr/openv/netbackup/bin/admincmd/bpstuadd"
BPSTULIST="/usr/openv/netbackup/bin/admincmd/bpstulist"

# ===== Checks =====
if [ ! -x "$BPSTUADD" ]; then
    echo "ERROR: bpstuadd not found at $BPSTUADD"
    exit 1
fi

if [ ! -d "$STU_PATH" ]; then
    echo "Creating storage directory: $STU_PATH"
    mkdir -p "$STU_PATH" || {
        echo "ERROR: Could not create directory $STU_PATH"
        exit 1
    }
fi

# Check whether storage unit already exists
$BPSTULIST "$STU_NAME" >/dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "ERROR: Storage unit '$STU_NAME' already exists."
    exit 1
fi

# ===== Create storage unit =====
echo "Creating BasicDisk storage unit '$STU_NAME'..."

"$BPSTUADD" \
    -label "$STU_NAME" \
    -path "$STU_PATH" \
    -dt 1 \
    -host "$MEDIA_SERVER" \
    -cj "$MAX_JOBS" \
    -hwm "$HIGH_WATER_MARK" \
    -lwm "$LOW_WATER_MARK" \
    -odo "$ON_DEMAND_ONLY" \
    -okrt "$OK_ON_ROOT" \
    -verbose

RC=$?

if [ $RC -ne 0 ]; then
    echo "ERROR: Failed to create storage unit. Return code: $RC"
    exit $RC
fi

echo
echo "Storage unit created successfully. Verifying..."
"$BPSTULIST" "$STU_NAME"

exit 0