#!/bin/bash

PLUGIN_DIR="$HOME/.local/share/opengamepadui/plugins"

rm -rf "$PLUGIN_DIR/fan-manager" "$PLUGIN_DIR/fan-manager.zip"
rm ./fan-manager.zip

make dist

cp ./fan-manager.zip "$PLUGIN_DIR/"
