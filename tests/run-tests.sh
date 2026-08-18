#!/bin/bash
# Sets up this test harness the same way .github/workflows/test.yml does
# (GUT addon + the plugins/fan-manager symlink, neither committed, see
# ../.gitignore), only doing whatever part is actually missing, then runs
# the GUT suite. Pass --setup-only to just do the setup and skip running
# tests (used by CI to import the project before the timed test run).
#
# GODOT_BIN can override the godot binary to use (defaults to whatever
# "godot" resolves to in PATH).

set -euo pipefail

GUT_VERSION="v9.2.0" # matches addons/gut/plugin.cfg's declared version
GODOT_BIN="${GODOT_BIN:-godot}"

setup_only=false
[[ "${1:-}" == "--setup-only" ]] && setup_only=true

cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ ! -f addons/gut/gut_cmdln.gd ]]; then
	echo "addons/gut is missing, downloading GUT ${GUT_VERSION}..."
	mkdir -p addons

	tmp_dir="$(mktemp -d)"
	trap 'rm -rf "$tmp_dir"' EXIT

	curl -sL -o "$tmp_dir/gut.zip" \
		"https://github.com/bitwes/Gut/archive/refs/tags/${GUT_VERSION}.zip"
	unzip -q "$tmp_dir/gut.zip" -d "$tmp_dir/extracted"
	rm -rf addons/gut
	cp -r "$tmp_dir/extracted"/Gut-*/addons/gut addons/gut

	# v9.2.0's utils.gd declares `var Logger = load(...)`, which Godot
	# 4.7+ rejects ("member shadows a native class") since it added its
	# own native Logger class. Not fixed upstream in this tag yet.
	sed -i 's/\bLogger\b/GutLogger/g' addons/gut/utils.gd
else
	echo "addons/gut already present, skipping download."
fi

link_target="../.."
if [[ -L plugins/fan-manager && "$(readlink plugins/fan-manager)" == "$link_target" ]]; then
	echo "plugins/fan-manager symlink already correct, skipping."
else
	echo "(re)creating plugins/fan-manager -> $link_target"
	mkdir -p plugins
	rm -f plugins/fan-manager
	ln -s "$link_target" plugins/fan-manager
fi

if $setup_only; then
	exit 0
fi

exec "$GODOT_BIN" --headless --path . \
	-s res://addons/gut/gut_cmdln.gd \
	-gdir=res://plugins/fan-manager/core -ginclude_subdirs \
	-gprefix= -gsuffix=_test.gd -gexit
