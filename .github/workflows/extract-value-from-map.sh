#!/bin/bash

# Usage: ./[script].sh -d? "DEFAULT_VALUE" -k "KEY" -m "BRANCH_MAP_JSON"
# -d is optional
# -b and -k are required if -d not provided

verbose=""

# Extract Args to nicer variables
while getopts k:m:d:v flag; do
    case "${flag}" in
    k) key=${OPTARG} ;;
    m) map=${OPTARG} ;;
    d) default=${OPTARG} ;;
    v) verbose="true" ;;
    esac
done

# Check if we have a provided deployenv
if [ ! -z "$default" ]; then
    echo "$default"
    exit 0 # Exit early, we got our value
fi

# Validate flags
if [ -z "$key" ] || [ -z "$map" ]; then
    echo "Missing -k[ey] or -m[ap] flag. Both are required."
    exit 1
fi

if [ "$verbose" != "" ]; then
    echo "Provided Map:"
    echo "$map" | jq -r "."
fi

echo "$map" | jq -r ".$key"
