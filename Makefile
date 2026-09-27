APP  = build/AgentLimits.app
DEST = /Applications/AgentLimits.app
# Where `make install-cli` puts the `agent-limits` command.
BIN_DIR ?= $(HOME)/.local/bin

.PHONY: build run install install-cli clean

# Compile and assemble the .app bundle into build/.
build:
	scripts/build_app.sh

# Build, then run the bundle from build/ (for quick iteration).
run:
	scripts/build_app.sh --run

# Build, then replace the copy in /Applications, re-sign, and relaunch it.
install: build
	-pkill -f "AgentLimits.app"
	rm -rf "$(DEST)"
	cp -R "$(APP)" "$(DEST)"
	codesign --force --sign - "$(DEST)"
	open "$(DEST)"
	@echo "Installed and launched: $(DEST)"

# Build and install the `agent-limits` CLI into $(BIN_DIR).
install-cli:
	swift build -c release --product agent-limits
	mkdir -p "$(BIN_DIR)"
	cp "$$(swift build -c release --show-bin-path)/agent-limits" "$(BIN_DIR)/agent-limits"
	@echo "Installed: $(BIN_DIR)/agent-limits"

clean:
	rm -rf .build build
