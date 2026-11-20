#!/bin/bash
# Quick Action: zip each selected file, with a progress window.
#
# In Automator: New Quick Action, "Workflow receives current files or folders in Finder",
# add "Run Shell Script", set "Pass input" to "as arguments", and paste this in.

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

total=$#
id=$(progress-helper start --watch-pid $$ --icon "$1" --label "Preparing…" --indeterminate)

i=0
for file in "$@"; do
    progress-helper cancelled "$id" && break
    progress-helper update "$id" --icon "$file" \
        --label "Compressing “$(basename "$file")”" \
        --total "$total" --completed "$i" --status "$((i + 1)) of $total"
    ditto -c -k --sequesterRsrc --keepParent "$file" "$file.zip"
    i=$((i + 1))
done

progress-helper end "$id"
