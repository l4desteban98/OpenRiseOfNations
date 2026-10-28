#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
"${CXX:-c++}" -std=c++17 -Wall -Wextra -pedantic -I engine \
  engine/sim/skirmish.cpp tests/skirmish.cpp -o build/tests/skirmish
build/tests/skirmish
