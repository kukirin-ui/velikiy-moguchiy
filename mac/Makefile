.PHONY: build build-mic-warm build-rust build-xcode generate clean run install-cli install-app

ARCH := aarch64-apple-darwin
XCODE_ARCH := arm64
# Self-signed identity made by scripts/setup-codesign-identity.sh; one created
# before the rename ("Koe Dev") is still used. macOS keeps the granted permissions
# only while the bundle identifier stays the same as well (see
# MacApp/Config/Secrets.xcconfig.example).
SIGN_IDENTITY := Velikiy Moguchiy Dev
LEGACY_SIGN_IDENTITY := Koe Dev

build: generate build-rust build-xcode build-mic-warm install-cli

build-mic-warm:
	swift build -c release --package-path vendor/mic-warm

generate:
	cd MacApp && xcodegen generate

build-rust:
	SHERPA_ONNX_LIB_DIR="$$(scripts/sherpa-onnx-libs.sh)" cargo build --manifest-path velikiy-moguchiy-core/Cargo.toml --release --target $(ARCH) --no-default-features --features "apple-speech,sherpa-onnx"
	cargo build --package velikiy-moguchiy-cli --release --target $(ARCH)

build-xcode:
	cd MacApp && xcodebuild -project VelikiyMoguchiy.xcodeproj -scheme VelikiyMoguchiy -configuration Release -skipPackagePluginValidation -skipMacroValidation ARCHS=$(XCODE_ARCH) build

install-cli: build-mic-warm
	@APP_ROOT=$$(xcodebuild -project MacApp/VelikiyMoguchiy.xcodeproj -scheme VelikiyMoguchiy -configuration Release -showBuildSettings 2>/dev/null | grep ' TARGET_BUILD_DIR' | head -1 | awk '{print $$3}')/VelikiyMoguchiy.app; \
	APP_DIR="$$APP_ROOT/Contents/MacOS"; \
	cp target/$(ARCH)/release/velikiy-moguchiy "$$APP_DIR/velikiy-moguchiy-cli"; \
	chmod +x "$$APP_DIR/velikiy-moguchiy-cli"; \
	cp vendor/mic-warm/.build/release/mic-warm "$$APP_DIR/mic-warm"; \
	chmod +x "$$APP_DIR/mic-warm"; \
	ENT="MacApp/VelikiyMoguchiy/VelikiyMoguchiy.entitlements"; \
	IDENTITY=""; \
	for CANDIDATE in "$(SIGN_IDENTITY)" "$(LEGACY_SIGN_IDENTITY)"; do \
		if security find-identity -p codesigning -v 2>/dev/null | grep -q "$$CANDIDATE"; then IDENTITY="$$CANDIDATE"; break; fi; \
	done; \
	if [ -n "$$IDENTITY" ]; then \
		echo "Signing with stable identity '$$IDENTITY' (Hardened Runtime — TCC permissions survive upgrades)"; \
		codesign --force --deep --sign "$$IDENTITY" --options runtime --entitlements "$$ENT" --timestamp=none "$$APP_ROOT"; \
	else \
		echo "No '$(SIGN_IDENTITY)' identity in keychain — ad-hoc signing (TCC re-prompts every build; run scripts/setup-codesign-identity.sh once to fix)"; \
		codesign --force --deep --sign - "$$APP_ROOT"; \
	fi; \
	codesign --verify --deep --strict --verbose=2 "$$APP_ROOT"; \
	echo "Installed velikiy-moguchiy-cli into $$APP_DIR and re-signed $$APP_ROOT"

# install-cli also signs the bundle with the stable identity: an ad-hoc
# signature changes with every build, and macOS then silently drops the
# Accessibility grant, so dictated text can no longer be typed or pasted.
install-app: install-cli
	@APP_ROOT=$$(xcodebuild -project MacApp/VelikiyMoguchiy.xcodeproj -scheme VelikiyMoguchiy -configuration Release -showBuildSettings 2>/dev/null | grep ' TARGET_BUILD_DIR' | head -1 | awk '{print $$3}')/VelikiyMoguchiy.app; \
	if [ ! -d "$$APP_ROOT" ]; then \
		echo "Release app not found at $$APP_ROOT. Run 'make build' first."; \
		exit 1; \
	fi; \
	codesign --verify --deep --strict --verbose=2 "$$APP_ROOT"; \
	rm -rf "/Applications/VelikiyMoguchiy.app"; \
	ditto "$$APP_ROOT" "/Applications/VelikiyMoguchiy.app"; \
	codesign --verify --deep --strict --verbose=2 "/Applications/VelikiyMoguchiy.app"; \
	echo "Installed /Applications/VelikiyMoguchiy.app from $$APP_ROOT"; \
	if [ -d "/Applications/Govorun.app" ]; then \
		echo "Note: the build from before the rename is still installed as /Applications/Govorun.app; quit and delete it (and turn Launch at Login on again in the new app)."; \
	fi

clean:
	cargo clean
	cd MacApp && xcodebuild -project VelikiyMoguchiy.xcodeproj -scheme VelikiyMoguchiy clean

run:
	open "$$(xcodebuild -project MacApp/VelikiyMoguchiy.xcodeproj -scheme VelikiyMoguchiy -configuration Debug -showBuildSettings 2>/dev/null | grep ' BUILD_DIR' | head -1 | awk '{print $$3}')/Debug/VelikiyMoguchiy.app"
