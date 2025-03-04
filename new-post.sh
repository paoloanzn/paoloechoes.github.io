#!/bin/bash

# Check if the argument is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <post-name>"
    exit 1
fi

# Get the current date in yyyy-mm-dd format
current_date=$(date +%F)

# Create the file name
file_name="${current_date}-$1.md"

# Create the new file inside the _posts folder
touch "_posts/${file_name}"

echo "New post created: _posts/${file_name}"