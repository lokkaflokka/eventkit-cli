PREFIX ?= ~/.local
BUILD_DIR = /tmp/eventkit-build

.PHONY: build install uninstall clean release

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

# Full release: install, tag, push, update Homebrew formula
# Usage: make release V=1.3.7
release: install
	@if [ -z "$(V)" ]; then echo "Usage: make release V=x.y.z"; exit 1; fi
	@CURRENT=$$(grep 'let version' Sources/main.swift | sed 's/.*"\(.*\)"/\1/'); \
	if [ "$$CURRENT" != "$(V)" ]; then \
		echo "Error: Sources/main.swift says $$CURRENT, not $(V). Bump version first."; exit 1; \
	fi
	git tag v$(V)
	git push origin main
	git push origin v$(V)
	@echo "---"
	@echo "Tagged and pushed v$(V)."
	@SHA=$$(curl -sL https://github.com/lokkaflokka/eventkit-cli/archive/refs/tags/v$(V).tar.gz | shasum -a 256 | cut -d' ' -f1); \
	echo "Homebrew SHA: $$SHA"; \
	echo "Update ~/mcp_personal_dev/mcp-authored/homebrew-tap/Formula/eventkit-cli.rb:"; \
	echo "  url → v$(V).tar.gz"; \
	echo "  sha256 → $$SHA"; \
	echo "  test → eventkit $(V)"
