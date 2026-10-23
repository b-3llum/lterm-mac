PROJECT = LtermMac.xcodeproj
DERIVED ?= $(HOME)/Library/Developer/Xcode/DerivedData/lterm-mac
APP = $(DERIVED)/Build/Products/Debug/lterm-mac.app
# SwiftPM build folder. Kept outside the repo because iCloud Desktop sync can touch files mid build.
SPM_SCRATCH ?= $(HOME)/Library/Caches/lterm-mac/spm

.PHONY: all project build cli test run release clean

all: build

project:
	xcodegen generate

build: project
	xcodebuild -project $(PROJECT) -scheme LtermMac -configuration Debug -derivedDataPath $(DERIVED) -skipPackagePluginValidation -skipMacroValidation build

release: project
	xcodebuild -project $(PROJECT) -scheme LtermMac -configuration Release -derivedDataPath $(DERIVED) -skipPackagePluginValidation -skipMacroValidation build

cli:
	swift build --scratch-path $(SPM_SCRATCH)

test:
	swift test --scratch-path $(SPM_SCRATCH)

run: build
	open $(APP)

clean:
	rm -rf $(DERIVED) $(SPM_SCRATCH) .build $(PROJECT)
