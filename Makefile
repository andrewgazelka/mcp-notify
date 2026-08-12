# Out-of-band build for the Swift daemon.
#
# nix cannot build this: the Metal compiler resolves into a cryptex mount
# (/var/run/com.apple.security.cryptexd/.../MetalToolchain...), SwiftPM wants
# network resolution for ~6 packages, the SDK is Xcode-only, and the model
# weights are multi-GB. nix ships the Rust CLI and the launchd plist; this
# Makefile ships notifyd.

PREFIX      ?= $(HOME)/.local
LIBEXEC     := $(PREFIX)/libexec/notifyd
DERIVED     := notifyd/.build/xcode
PRODUCTS    := $(DERIVED)/Build/Products/Release
LAUNCHD_LBL ?= org.nix-community.home.notifyd

XCFLAGS := -scheme notifyd -configuration Release -destination 'platform=macOS' \
           -derivedDataPath .build/xcode \
           -skipPackagePluginValidation -skipMacroValidation

.PHONY: notifyd install-notifyd selftest bench clean-notifyd

notifyd:
	cd notifyd && xcodebuild $(XCFLAGS) -quiet

# Two metallib placements, deliberately. mlx-swift looks for the SwiftPM
# bundle first and falls back to a colocated `mlx.metallib`; which one wins
# depends on how the binary was launched (launchd vs shell), so install both
# and stop caring.
install-notifyd: notifyd
	@test -x $(PRODUCTS)/notifyd || { echo "no binary at $(PRODUCTS)/notifyd"; exit 1; }
	@test -f $(PRODUCTS)/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib \
	  || { echo "no metallib in build products - Metal did not compile"; exit 1; }
	mkdir -p $(LIBEXEC)
	rm -rf $(LIBEXEC)/mlx-swift_Cmlx.bundle
	cp -R $(PRODUCTS)/mlx-swift_Cmlx.bundle $(LIBEXEC)/
	cp $(PRODUCTS)/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib $(LIBEXEC)/mlx.metallib
	# Install to a temp name and mv: `cp` over a running binary can fail with
	# ETXTBSY, and even when it works launchd keeps the old inode.
	cp $(PRODUCTS)/notifyd $(LIBEXEC)/notifyd.new
	mv -f $(LIBEXEC)/notifyd.new $(LIBEXEC)/notifyd
	@echo "installed $(LIBEXEC)/notifyd"
	@# Gate the restart on the installed layout actually working. A daemon that
	@# cannot reach Metal should not be handed the socket.
	$(LIBEXEC)/notifyd --selftest-metal
	@launchctl kickstart -k gui/$(shell id -u)/$(LAUNCHD_LBL) \
	  && echo "restarted $(LAUNCHD_LBL)" \
	  || echo "launchd label $(LAUNCHD_LBL) not loaded (fine - notify falls back to say)"

selftest: install-notifyd
	$(LIBEXEC)/notifyd --selftest-metal

bench: install-notifyd
	$(LIBEXEC)/notifyd --bench --engine holler --n 20

clean-notifyd:
	rm -rf $(DERIVED)
