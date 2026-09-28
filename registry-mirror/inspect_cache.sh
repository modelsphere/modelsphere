#!/bin/bash

# Default IP, can be overridden by passing an argument to the script
IP="${1:-127.0.0.1}"   # the host running docker-compose.yaml
PORTS=("5001" "5002" "5003" "5004" "5005" "5006")

echo "================================================="
echo " Inspecting Local Cache Registries on $IP "
echo "================================================="

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' is not installed. Please install it (e.g., apt install jq) to run this script."
    exit 1
fi

for PORT in "${PORTS[@]}"; do
    echo ""
    echo "-------------------------------------------------"
    if [ "$PORT" -eq 5001 ]; then echo " 🐳 docker.io (Port $PORT)"; fi
    if [ "$PORT" -eq 5002 ]; then echo " ☸️  registry.k8s.io / k8s.gcr.io (Port $PORT)"; fi
    if [ "$PORT" -eq 5003 ]; then echo " 🚢 quay.io (Port $PORT)"; fi
    if [ "$PORT" -eq 5004 ]; then echo " ☁️  gcr.io (Port $PORT)"; fi
    if [ "$PORT" -eq 5005 ]; then echo " 🐙 ghcr.io (Port $PORT)"; fi
    if [ "$PORT" -eq 5006 ]; then echo " 🟢 nvcr.io (Port $PORT)"; fi
    echo "-------------------------------------------------"

    # Fetch catalog
    CATALOG=$(curl -s --fail -m 2 "http://$IP:$PORT/v2/_catalog")
    
    if [ $? -ne 0 ]; then
        echo "   [!] Cache offline or unreachable"
        continue
    fi
    
    # Parse repositories
    REPOS=$(echo "$CATALOG" | jq -r '.repositories[]?' 2>/dev/null)

    if [ -z "$REPOS" ]; then
        echo "   (Empty - No images cached yet)"
        continue
    fi

    # List the cached repositories (pull-through proxies do not expose tags via API)
    for REPO in $REPOS; do
        echo "   📦 $REPO"
    done
done
echo ""
