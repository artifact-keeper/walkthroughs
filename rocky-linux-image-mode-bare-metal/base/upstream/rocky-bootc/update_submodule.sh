#!/bin/bash
set -xeuo pipefail

if [ ! -f ".gitmodules" ]; then
  echo "No .gitmodules file found. No submodules defined."
  exit 0
fi

check_submodule() {
  local submodule_path="$1"
  local submodule_name="$2"

  echo "Checking submodule: $submodule_name ($submodule_path)"

  if [ ! -d "$submodule_path" ]; then
    echo "  Status: Directory missing (not initialized)"
    return 1
  fi

  if [ -z "$(find "$submodule_path" -maxdepth 1 -not -path "$submodule_path" -not -name ".git")" ]; then
    echo "  Status: Directory is empty (not cloned)"
    return 1
  fi

  if [ ! -f "$submodule_path/.git" ]; then
    echo "  Status: .git file missing (not initialized)"
    return 1
  fi

  echo "  Status: Cloned and initialized"
  return 0
}

while IFS= read -r line; do
  if [[ $line =~ ^\[submodule\ \"(.*)\"\]$ ]]; then
    submodule_name="${BASH_REMATCH[1]}"
  elif [[ $line =~ ^[[:space:]]*path[[:space:]]*=[[:space:]]*(.*)$ ]]; then
    submodule_path="${BASH_REMATCH[1]}"
    if [ -n "$submodule_name" ] && [ -n "$submodule_path" ]; then
      if check_submodule "$submodule_path" "$submodule_name"; then
        if git diff --quiet "$submodule_path" && git diff --quiet --cached "$submodule_path"; then
          git submodule update --init --recursive "$submodule_path"
        else
          (cd "$submodule_path" && git submodule update --init --recursive)
        fi
      else
        git submodule update --init --recursive "$submodule_path"
      fi
      submodule_name=""
      submodule_path=""
    fi
  fi
done <".gitmodules"
