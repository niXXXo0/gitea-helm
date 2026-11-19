#!/bin/sh

set -eu

# --------------------------------------------------
# Configuration
# --------------------------------------------------

NAMESPACE="${NAMESPACE:?NAMESPACE is required}"
RELEASE_NAME="${RELEASE_NAME:?RELEASE_NAME is required}"

DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-gitea}"

GITEA_DATA_DIR="${GITEA_DATA_DIR:-/gitea-data}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"

PGHOST="${PGHOST:-postgres}"
PGPORT="${PGPORT:-5432}"
PGDATABASE="${PGDATABASE:?PGDATABASE is required}"
PGUSER="${PGUSER:?PGUSER is required}"
PGPASSWORD="${PGPASSWORD:?PGPASSWORD is required}"

RETENTION_DAYS="${RETENTION_DAYS:-14}"
POD_TERMINATION_TIMEOUT="${POD_TERMINATION_TIMEOUT:-180}"

export PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD

# --------------------------------------------------
# Backup state
# --------------------------------------------------

ORIGINAL_REPLICAS=""
RESTORE_REQUIRED="false"
TEMP_DIR=""

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_NAME="gitea-${TIMESTAMP}"

TEMP_DIR="${BACKUP_DIR}/.${BACKUP_NAME}.tmp"
FINAL_DIR="${BACKUP_DIR}/${BACKUP_NAME}"

POD_SELECTOR="app.kubernetes.io/name=gitea,app.kubernetes.io/instance=${RELEASE_NAME}"

# --------------------------------------------------
# Cleanup and restore
# --------------------------------------------------

cleanup() {
    EXIT_CODE=$?

    trap - EXIT INT TERM

    echo "Starting cleanup..."

    # Remove incomplete backup
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        echo "Removing incomplete backup..."
        rm -rf "$TEMP_DIR"
    fi

    # Restore original Gitea replica count
    if [ "$RESTORE_REQUIRED" = "true" ]; then
        echo "Restoring Gitea replicas: ${ORIGINAL_REPLICAS}"

        if kubectl scale deployment "$DEPLOYMENT_NAME" \
            --replicas="$ORIGINAL_REPLICAS" \
            -n "$NAMESPACE"; then

            if [ "$ORIGINAL_REPLICAS" -gt 0 ]; then
                echo "Waiting for Gitea to become ready..."

                if ! kubectl rollout status deployment "$DEPLOYMENT_NAME" \
                    -n "$NAMESPACE" \
                    --timeout=180s; then

                    echo "ERROR: Gitea did not become ready!"
                    EXIT_CODE=1
                fi
            fi
        else
            echo "ERROR: Failed to restore Gitea replicas!"
            EXIT_CODE=1
        fi
    fi

    echo "Cleanup finished."

    exit "$EXIT_CODE"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --------------------------------------------------
# Pre-backup checks
# --------------------------------------------------

echo "Starting Gitea backup..."

if [ ! -d "$GITEA_DATA_DIR" ]; then
    echo "ERROR: Gitea data directory does not exist!"
    exit 1
fi

mkdir -p "$BACKUP_DIR"

# Check backup storage is writable
TEST_FILE="${BACKUP_DIR}/.write-test-$$"
touch "$TEST_FILE"
rm -f "$TEST_FILE"

# Check PostgreSQL connection and authentication
echo "Checking PostgreSQL connection..."

psql \
    -v ON_ERROR_STOP=1 \
    -c "SELECT 1;" \
    > /dev/null

echo "PostgreSQL connection successful."

# --------------------------------------------------
# Prepare backup directory
# --------------------------------------------------

mkdir "$TEMP_DIR"

# --------------------------------------------------
# Save original replica count
# --------------------------------------------------

echo "Getting current Gitea replica count..."

ORIGINAL_REPLICAS="$(kubectl get deployment "$DEPLOYMENT_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.spec.replicas}')"

case "$ORIGINAL_REPLICAS" in
    ''|*[!0-9]*)
        echo "ERROR: Invalid replica count: ${ORIGINAL_REPLICAS}"
        exit 1
        ;;
esac

echo "Original replicas: ${ORIGINAL_REPLICAS}"

RESTORE_REQUIRED="true"

# --------------------------------------------------
# Stop Gitea
# --------------------------------------------------

echo "Stopping Gitea..."

kubectl scale deployment "$DEPLOYMENT_NAME" \
    --replicas=0 \
    -n "$NAMESPACE"

# --------------------------------------------------
# Wait until Gitea Pods terminate
# --------------------------------------------------

echo "Waiting for Gitea Pods to terminate..."

ELAPSED=0

while [ "$ELAPSED" -lt "$POD_TERMINATION_TIMEOUT" ]; do

    PODS="$(kubectl get pods \
        -n "$NAMESPACE" \
        -l "$POD_SELECTOR" \
        -o name)"

    if [ -z "$PODS" ]; then
        break
    fi

    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

if [ -n "$PODS" ]; then
    echo "ERROR: Gitea Pods did not terminate in time!"
    exit 1
fi

echo "Gitea is stopped."

# --------------------------------------------------
# Backup Gitea files
# --------------------------------------------------

echo "Creating Gitea files archive..."

tar -czf "${TEMP_DIR}/gitea-files.tar.gz" \
    -C "$GITEA_DATA_DIR" .

# Verify archive
tar -tzf "${TEMP_DIR}/gitea-files.tar.gz" > /dev/null

echo "Gitea files archive created."

# --------------------------------------------------
# Backup PostgreSQL
# --------------------------------------------------

echo "Creating PostgreSQL dump..."

pg_dump \
    -h "$PGHOST" \
    -p "$PGPORT" \
    -U "$PGUSER" \
    -d "$PGDATABASE" \
    -Fc \
    -f "${TEMP_DIR}/gitea-db.dump"

# Verify database dump
pg_restore --list "${TEMP_DIR}/gitea-db.dump" > /dev/null

echo "PostgreSQL dump created."

# --------------------------------------------------
# Generate checksums
# --------------------------------------------------

echo "Generating checksums..."

cd "$TEMP_DIR"

sha256sum \
    gitea-files.tar.gz \
    gitea-db.dump \
    > checksums.sha256

cd /

# --------------------------------------------------
# Publish completed backup
# --------------------------------------------------

echo "Publishing backup..."

mv "$TEMP_DIR" "$FINAL_DIR"

echo "Backup completed successfully: ${FINAL_DIR}"

# --------------------------------------------------
# Backup retention
# --------------------------------------------------

echo "Removing backups older than ${RETENTION_DAYS} days..."

find "$BACKUP_DIR" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -name 'gitea-*' \
    -mtime "+${RETENTION_DAYS}" \
    -exec rm -rf {} \;

echo "Backup process finished."