#!/bin/bash

# NetBackup 11 - Add Active Directory domain for authentication/RBAC
# This script adds an AD domain to NetBackup using vssat addldapdomain
# and validates a test user.
#
# Run on the NetBackup primary server as root or a NetBackup admin account.

set -euo pipefail

# ===== User-editable variables =====
DOMAIN_NAME="cohesitylabs.az"
LDAP_URL="ldap://cohesitylabs.az:389"
USER_BASE_DN="CN=Users,DC=cohesitylabs,DC=cohesitylabs,DC=az"
GROUP_BASE_DN="CN=Users,DC=cohesitylabs,DC=cohesitylabs,DC=az"
BIND_DN="CN=svc_netbackup,CN=Users,DC=cohesitylabs,DC=cohesitylabs,DC=az"
BROWSE_MODE="BOB"                 # FLAT or BOB
SCHEMA_TYPE="msad"                # Active Directory = msad
TEST_USER="administrator"         # sAMAccountName/user to validate after add

# Optional LDAPS CA file. Leave empty for ldap:// or if not needed.
TRUSTED_CA_FILE=""

# ===== Command path =====
VSSAT="/usr/openv/netbackup/sec/at/bin/vssat"

# ===== Checks =====
if [[ ! -x "$VSSAT" ]]; then
    echo "ERROR: vssat not found at $VSSAT"
    exit 1
fi

echo "This will add AD domain '$DOMAIN_NAME' to NetBackup."
read -rsp "Enter bind password for $BIND_DN: " BIND_PASSWORD
echo

# ===== Build add command =====
ADD_CMD=(
  "$VSSAT" addldapdomain
  -d "$DOMAIN_NAME"
  -s "$LDAP_URL"
  -u "$USER_BASE_DN"
  -g "$GROUP_BASE_DN"
  -t "$SCHEMA_TYPE"
  -m "$BIND_DN"
  -w "$BIND_PASSWORD"
  -b "$BROWSE_MODE"
)

# Add CA file only if specified
if [[ -n "$TRUSTED_CA_FILE" ]]; then
  ADD_CMD+=( -f "$TRUSTED_CA_FILE" )
fi

echo "Adding AD domain to NetBackup..."
"${ADD_CMD[@]}"

echo
echo "Listing configured LDAP/AD domains..."
"$VSSAT" listldapdomains

echo
echo "Validating test user '$TEST_USER' in domain '$DOMAIN_NAME'..."
"$VSSAT" validateprpl \
  -p "$TEST_USER" \
  -d "ldap:$DOMAIN_NAME" \
  -b "localhost:1556:nbatd"

echo
echo "Success: AD domain '$DOMAIN_NAME' was added and test user validation completed."