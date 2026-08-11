NAME := fan-manager
OGUI_DIR := ../OpenGamepadUI
PLUGIN_DIR := $(OGUI_DIR)/plugins
BUILD_DIR := build
DIST_DIR := dist

.PHONY: help
help:
	@echo "Available targets:"
	@echo "  build    - symlink this plugin into OpenGamepadUI/plugins for development"
	@echo "  clean    - remove the development symlink and build artifacts"
	@echo "  dist     - package the plugin as a zip for installation into user://plugins"

.PHONY: build
build:
	mkdir -p $(PLUGIN_DIR)
	ln -sfn $(CURDIR) $(PLUGIN_DIR)/$(NAME)
	@echo "Linked $(CURDIR) -> $(PLUGIN_DIR)/$(NAME)"
	@echo "Now run 'make edit' inside $(OGUI_DIR) to open the Godot editor"

.PHONY: clean
clean:
	rm -f $(PLUGIN_DIR)/$(NAME)
	rm -rf $(BUILD_DIR) $(DIST_DIR)

.PHONY: dist
dist:
	mkdir -p $(DIST_DIR)/plugins/$(NAME)
	cp -r plugin.json plugin.gd core assets $(DIST_DIR)/plugins/$(NAME)/
	cd $(DIST_DIR) && zip -r ../$(NAME).zip plugins
	rm -rf $(DIST_DIR)
	@echo "Created $(NAME).zip"
