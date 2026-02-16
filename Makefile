PREFIX ?= ~/.local
BUILD_DIR = /tmp/eventkit-build

.PHONY: build install uninstall clean

build:
	swift build -c release --build-path $(BUILD_DIR)

install: build
	mkdir -p $(PREFIX)/bin
	cp $(BUILD_DIR)/release/eventkit $(PREFIX)/bin/eventkit
	chmod +x $(PREFIX)/bin/eventkit
	@echo "Installed: $$($(PREFIX)/bin/eventkit --version)"

uninstall:
	rm -f $(PREFIX)/bin/eventkit

clean:
	rm -rf $(BUILD_DIR)
