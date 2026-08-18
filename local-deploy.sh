#!/bin/bash

PLUGIN_DIR="$HOME/.local/share/opengamepadui/plugins"

rm -rf "$PLUGIN_DIR/fan-manager" "$PLUGIN_DIR/fan-manager.zip"
rm ./fan-manager.zip

make dist

cp ./fan-manager.zip "$PLUGIN_DIR/"


if [[ ! -f /etc/fan-manager/fan-manager-priv-write || ! -f /etc/systemd/system/fan-manager-priv-write@.service || ! -f /etc/polkit-1/rules.d/50-fan-manager.rules ]]; then
	sudo mkdir -p /etc/fan-manager
	sudo cp policy/fan-manager-priv-write /etc/fan-manager/fan-manager-priv-write
	sudo chown root:root /etc/fan-manager/fan-manager-priv-write
	sudo chmod 755 /etc/fan-manager/fan-manager-priv-write

	sudo cp policy/fan-manager-priv-write@.service /etc/systemd/system/
	sudo chown root:root /etc/systemd/system/fan-manager-priv-write@.service
	sudo chmod 644 /etc/systemd/system/fan-manager-priv-write@.service

	sudo cp policy/50-fan-manager.rules /etc/polkit-1/rules.d/
	sudo chown root:root /etc/polkit-1/rules.d/50-fan-manager.rules
	sudo chmod 644 /etc/polkit-1/rules.d/50-fan-manager.rules

	sudo systemctl daemon-reload
fi
