APP  = build/AgentLimits.app
DEST = /Applications/AgentLimits.app

.PHONY: build run install clean

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

clean:
	rm -rf .build build
