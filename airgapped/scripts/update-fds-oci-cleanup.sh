#!/bin/bash
# ==============================================================================
# Script: update-fds-oci-cleanup.sh
# Description: Toggle automatic cleanup of orphaned OCI images in FDS
# Usage: ./update-fds-oci-cleanup.sh [true|false]
# ==============================================================================

set -eo pipefail

# Print help message if no argument is passed, or if -h/--help is requested
if [ "$#" -eq 0 ] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
  echo "Usage: $0 [true|false]"
  echo ""
  echo "  true   - Enable automatic deletion of orphaned OCI images in FDS"
  echo "  false  - Disable automatic deletion of orphaned OCI images in FDS"
  echo ""
  echo "Required Environment Variable:"
  echo "  ADMIN_PASSWORD  (Must be exported before running)"
  echo ""
  echo "Optional Environment Variables:"
  echo "  PLATFORM_HOST   (Default: https://platform.vrack.vsphere.local)"
  echo "  ADMIN_USERNAME  (Default: admin@vsp.local)"
  exit 0
fi

ENABLE_CLEANUP="$1"

if [[ "$ENABLE_CLEANUP" != "true" && "$ENABLE_CLEANUP" != "false" ]]; then
  echo "Error: Invalid argument '$1'."
  echo "Usage: $0 [true|false]"
  exit 1
fi

# Environment Configuration
PLATFORM_HOST="${PLATFORM_HOST:-https://platform.vrack.vsphere.local}"
ADMIN_USERNAME="${ADMIN_USERNAME:-admin@vsp.local}"

if [ -z "$ADMIN_PASSWORD" ]; then
  echo "Error: ADMIN_PASSWORD environment variable is not set."
  echo "Please run: export ADMIN_PASSWORD='<your_admin_password>'"
  exit 1
fi

echo "==> 1. Obtaining access token from VMSP Identity Service..."
TOKEN=$(curl -ks -X POST "${PLATFORM_HOST}/api/v1/identity/token" \
  --header 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "grant_type=password" \
  --data-urlencode "username=${ADMIN_USERNAME}" \
  --data-urlencode "password=${ADMIN_PASSWORD}" | jq -r '.access_token')

if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
  echo "Error: Failed to obtain authentication token. Check credentials or PLATFORM_HOST."
  exit 1
fi

echo "==> 2. Discovering FDS Component ID..."
COMPONENTS_RESP=$(curl -ks -X GET \
  -H "Authorization: Bearer ${TOKEN}" \
  "${PLATFORM_HOST}/api/v1/components")

FDS_COMP_ID=$(echo "$COMPONENTS_RESP" | jq -r '.components[] | select(.name == "vcf-fleet-depot") | .id // empty' | head -1)

if [ -z "$FDS_COMP_ID" ]; then
  echo "Error: Unable to find 'vcf-fleet-depot' component ID."
  exit 1
fi

echo "Found FDS Component ID: ${FDS_COMP_ID}"
echo "==> 3. Submitting configuration update (deleteOrphanedImagesEnabled=${ENABLE_CLEANUP})..."

PAYLOAD=$(cat <<EOF
{
  "spec": {
    "configuration": {
      "downloadService": {
        "artifacts": {
          "oci": {
            "deleteOrphanedImagesEnabled": ${ENABLE_CLEANUP}
          }
        }
      }
    }
  }
}
EOF
)

TASK_ID=$(curl -ks -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  "${PLATFORM_HOST}/api/v1/components/${FDS_COMP_ID}?action=apply" \
  -d "${PAYLOAD}" | jq -r '.id')

if [ -z "$TASK_ID" ] || [ "$TASK_ID" == "null" ]; then
  echo "Error: Failed to submit configuration task."
  exit 1
fi

echo "Task submitted successfully. Task ID: ${TASK_ID}"
echo "==> 4. Polling task status (Timeout: 20 minutes)..."

MAX_ATTEMPTS=120
SLEEP_INTERVAL=10
TASK_SUCCESS=false

for ((i=1; i<=MAX_ATTEMPTS; i++)); do
  TASK_RESP=$(curl -ks -X GET \
    -H "Authorization: Bearer ${TOKEN}" \
    "${PLATFORM_HOST}/api/v1/tasks/${TASK_ID}" 2>/dev/null || true)

  STATUS=$(echo "$TASK_RESP" | jq -r '.status // empty' 2>/dev/null || true)

  echo "Attempt ${i}/${MAX_ATTEMPTS} - Task Status: ${STATUS:-UNKNOWN}"

  if [ "$STATUS" == "Succeeded" ]; then
    echo "SUCCESS: FDS configuration updated. deleteOrphanedImagesEnabled is now set to '${ENABLE_CLEANUP}'."
    TASK_SUCCESS=true
    break
  elif [ "$STATUS" == "Failed" ]; then
    echo "ERROR: Configuration task failed."
    ERROR_MSG=$(echo "$TASK_RESP" | jq -r '.error // .message // empty' 2>/dev/null || true)
    [ -n "$ERROR_MSG" ] && echo "Details: ${ERROR_MSG}"
    exit 1
  fi

  sleep "${SLEEP_INTERVAL}"
done

if [ "$TASK_SUCCESS" != "true" ]; then
  echo "ERROR: Task did not complete within the 20-minute timeout."
  exit 1
fi
