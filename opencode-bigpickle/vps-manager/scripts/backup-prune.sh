#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
source "$LIB_DIR/common.sh"

ensure_root

RETENTION="${BACKUP_RETENTION_DAYS:-30}"
FIND_OPTS="-mtime +${RETENTION}"

pruned=0
while IFS= read -r -d '' bak; do
    [[ -d "$bak" ]] || continue
    rm -rf "$bak"
    pruned=$((pruned + 1))
    info "Pruned old backup: $bak"
done < <(find "$BACKUP_DIR" -maxdepth 1 -type d -name "${DOMAIN}_*" $FIND_OPTS -print0 2>/dev/null || true)

echo "Pruned ${pruned} backup(s) older than ${RETENTION} days from ${BACKUP_DIR}"
