#!/bin/zsh
# Builds the database layer with the checks in main.swift and runs them against live servers.
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build
swiftc -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
  MenuMySQL/{MySQLWire,Database,SSHTunnel,Language,TableDesign,ViewDesign,SchemaDocument,CSVImport}.swift tests/main.swift \
  -o build/tests
build/tests "$@"
