#!/bin/bash

# ll with filename length sorting

if ls -lah --color=always /dev/null >/dev/null 2>&1; then
    LS_OPTS="-lah --color=always"
elif ls -lah --color=auto /dev/null >/dev/null 2>&1; then
    LS_OPTS="-lah --color=auto"
else
    LS_OPTS="-lah"
fi

ll() {
    local temp_file=$(mktemp)
    ls $LS_OPTS "$@" > "$temp_file" 2>/dev/null

    # Show total line
    grep "^total" "$temp_file"

    # Extract and sort by category and length
    {
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ "$line" =~ ^total ]] && continue

            # Extract filename
            if [[ "$line" =~ ([0-9]{1,2}:[0-9]{2}|[0-9]{4})[[:space:]]+(.+)$ ]]; then
                filename="${BASH_REMATCH[2]}"
            else
                filename="${line##* }"
            fi

            # Clean filename for sorting
            clean_name=$(echo "$filename" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')

            # Determine category: 1=hidden files, 2=normal files, 3=hidden dirs, 4=normal dirs
            if [[ "$line" =~ ^d ]]; then
                if [[ "$clean_name" == .* ]]; then
                    category="3"  # hidden dirs
                else
                    category="4"  # normal dirs
                fi
            else
                if [[ "$clean_name" == .* ]]; then
                    category="1"  # hidden files
                else
                    category="2"  # normal files
                fi
            fi

            # Create sort key: category_length(padded)_name
            length=${#clean_name}
            printf "%s_%03d_%s\t%s\n" "$category" "$length" "$clean_name" "$line"

        done < "$temp_file"
    } | sort | cut -f2-

    rm -f "$temp_file"
}
