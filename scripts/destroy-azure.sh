#!/usr/bin/env bash
# Tear down the entire Azure deployment by deleting the resource group.
# Everything lives in claude-mcp-rg, so one delete removes it all (and stops all
# billing). Use this to keep costs at zero when you are not using the server.
#
# Usage:
#   bash scripts/destroy-azure.sh            # prompts for confirmation
#   bash scripts/destroy-azure.sh --yes      # no prompt

set -euo pipefail

RG="${AZURE_RESOURCE_GROUP:-claude-mcp-rg}"
ASSUME_YES=0
[ "${1:-}" = "--yes" ] && ASSUME_YES=1

command -v az >/dev/null 2>&1 || { echo "Error: 'az' CLI not found." >&2; exit 1; }
az account show >/dev/null 2>&1 || { echo "Error: not logged in. Run: az login" >&2; exit 1; }

if ! az group show --name "$RG" >/dev/null 2>&1; then
  echo "Resource group '$RG' does not exist; nothing to delete."
  exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  echo "This will DELETE the resource group '$RG' and every resource in it."
  printf "Type the resource group name to confirm: "
  read -r reply
  [ "$reply" = "$RG" ] || { echo "Aborted."; exit 1; }
fi

echo "==> Deleting resource group '$RG' (running in the background)..."
az group delete --name "$RG" --yes --no-wait
echo "Deletion started. Check with: az group show --name $RG"
