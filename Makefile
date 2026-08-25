APP        := dist/Monsieur.app
INSTALLED  := /Applications/Monsieur.app
BUNDLE_ID  := dev.enikiforov.monsieur

.PHONY: all build debug install run stop cert icon logs reset-permissions clean

all: build

## One-time: create the self-signed cert so permissions survive rebuilds.
cert:
	@Scripts/make-cert.sh

## One-time (optional): generate the app icon.
icon:
	@swift Scripts/makeicon.swift

build:
	@Scripts/bundle.sh

debug:
	@CONFIG=debug Scripts/bundle.sh

install: build
	@pkill -x Monsieur 2>/dev/null || true
	@sleep 0.3
	@rm -rf $(INSTALLED)
	@cp -R $(APP) $(INSTALLED)
	@echo "==> Installed to $(INSTALLED)"

## Build, install to /Applications (stable path for TCC) and launch.
run: install
	@open $(INSTALLED)

stop:
	@pkill -x Monsieur 2>/dev/null || true

logs:
	@log stream --style compact --predicate 'subsystem == "$(BUNDLE_ID)"' --level debug

reset-permissions:
	@tccutil reset Accessibility $(BUNDLE_ID) || true
	@tccutil reset Microphone $(BUNDLE_ID) || true
	@tccutil reset ListenEvent $(BUNDLE_ID) || true

clean:
	@rm -rf .build dist
