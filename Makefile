.PHONY: build run clean test

build: clean
	swift build --package-path App

run: build
	App/.build/debug/Dimroom

clean:
	rm -rf App/.build

test:
	bin/test-all.sh
