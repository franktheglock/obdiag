#!/usr/bin/env bash
# Parser regression checks — no Xcode, no simulator, a few seconds.
#
# Both bugs found on real hardware (VIN multi-frame parsing, the DTC count byte)
# were pure wire-format mistakes, so they are pinned here.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "▸ VIN parser"
swiftc -o "$WORK/vin" \
  OBDiag/OBD/OBDTypes.swift \
  OBDiag/Core/Models/Vehicle.swift \
  OBDiag/Core/Support/Extensions.swift \
  OBDiag/Core/Support/Formatters.swift \
  scripts/Tests/VINParser/main.swift
"$WORK/vin"

echo
echo "▸ DTC codec"
swiftc -o "$WORK/dtc" \
  OBDiag/OBD/DTCCodec.swift \
  scripts/Tests/DTCCodec/main.swift
"$WORK/dtc"
