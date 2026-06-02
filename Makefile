.PHONY: build run bundle clean test

# Incremental build of the SPM executable. Use `make clean build` to
# force a from-scratch rebuild.
build:
	swift build --package-path App

# Assemble Dimroom.app via bin/build-app-bundle.sh (Info.plist + icon),
# then launch it. This is the correct shape for AppKit affordances
# (Dock click, OAuth loopback, recent files); the bare SPM exe was a
# half-built binary at 1.0 review (#1.0-readiness blocker).
run: bundle
	open App/.build/debug/Dimroom.app

# Bundle target on its own — useful when you want the .app without
# launching it.
bundle:
	bin/build-app-bundle.sh

clean:
	rm -rf App/.build

test:
	bin/test-all.sh
