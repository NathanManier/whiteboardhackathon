#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
native_root="$(cd "${script_dir}/.." && pwd)"
project_file="${VBOARD_DESMOS_PROJECT_FILE:-${native_root}/VBoardApp.xcodeproj/project.pbxproj}"

usage() {
    echo "Usage: $(basename "$0") [DESMOS_API_KEY]" >&2
    echo >&2
    echo "With no argument, the script securely prompts for the key." >&2
    echo "Passing the key as an argument is supported for automation, but may save it in shell history." >&2
}

if [[ $# -gt 1 ]]; then
    usage
    exit 64
fi

if [[ $# -eq 1 ]]; then
    desmos_key="$1"
else
    read -r -s -p "Desmos API key: " desmos_key
    echo
fi

if [[ ${#desmos_key} -lt 8 ]]; then
    echo "Error: the Desmos API key must contain at least 8 characters." >&2
    exit 65
fi

if [[ "$desmos_key" == *$'\n'* || "$desmos_key" == *$'\r'* ]]; then
    echo "Error: the Desmos API key cannot contain a newline." >&2
    exit 65
fi

if [[ ! -f "$project_file" ]]; then
    echo "Error: Xcode project file not found: $project_file" >&2
    exit 66
fi

setting_count="$(grep -Ec '^[[:space:]]*VBOARD_DESMOS_API_KEY[[:space:]]*=' "$project_file" || true)"
if [[ "$setting_count" -ne 2 ]]; then
    echo "Error: expected exactly 2 VBOARD_DESMOS_API_KEY settings, found $setting_count." >&2
    echo "No files were changed." >&2
    exit 67
fi

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/vboard-desmos-key.XXXXXX")"
cleanup() {
    rm -rf "$temporary_dir"
}
trap cleanup EXIT

updated_project="${temporary_dir}/project.pbxproj"
export VBOARD_DESMOS_REPLACEMENT="$desmos_key"

perl -0pe '
    BEGIN {
        $key = $ENV{"VBOARD_DESMOS_REPLACEMENT"};
        $key =~ s/\\/\\\\/g;
        $key =~ s/"/\\"/g;
        $replacement = "\"$key\"";
        $count = 0;
    }

    $count += s/^([ \t]*VBOARD_DESMOS_API_KEY[ \t]*=[ \t]*).*?;([ \t]*)$/$1$replacement;$2/gm;

    END {
        if ($count != 2) {
            print STDERR "Error: expected to update 2 Desmos key settings, updated $count.\n";
            exit 68;
        }
    }
' "$project_file" > "$updated_project"

if ! grep -Fq '<string>$(VBOARD_DESMOS_API_KEY)</string>' "${native_root}/VBoardApp/Resources/Info.plist"; then
    echo "Error: the Debug Info.plist no longer references VBOARD_DESMOS_API_KEY." >&2
    exit 69
fi

if ! grep -Fq '<string>$(VBOARD_DESMOS_API_KEY)</string>' "${native_root}/VBoardApp/Resources/Info-Release.plist"; then
    echo "Error: the Release Info.plist no longer references VBOARD_DESMOS_API_KEY." >&2
    exit 69
fi

cp "$updated_project" "$project_file"
unset VBOARD_DESMOS_REPLACEMENT
desmos_key=""

echo "Updated the VBoardApp Debug and Release Desmos API key settings."
echo "Clean and rebuild VBoardApp so the new value is copied into the application bundle."

