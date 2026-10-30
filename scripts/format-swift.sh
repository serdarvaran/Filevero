#!/bin/zsh
# Formats every Swift file with the repository's .swift-format; --check only reports differences.
set -euo pipefail
cd "${0:A:h}/.."
files=(Package.swift ${(f)"$(git ls-files --cached --others --exclude-standard 'Sources/*.swift' 'Tests/*.swift' 'scripts/*.swift')"})
if [[ "${1:-}" == "--check" ]]; then
  swift format lint --strict --parallel "${files[@]}"
else
  swift format format --in-place --parallel "${files[@]}"
fi
