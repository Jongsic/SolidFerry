.PHONY: proj build run cli test format lint

proj:
	xcodegen generate --quiet

build: proj
	xcodebuild -project SolidFerry.xcodeproj -scheme SolidFerry -configuration Debug -derivedDataPath build/DerivedData.noindex -quiet build

run: build
	open build/DerivedData.noindex/Build/Products/Debug/SolidFerry.app

cli:
	cd Packages/SolidFerryKit && swift build -c release --product sferry

format:
	swiftformat .

lint:
	swiftformat --lint .

test:
	cd Packages/SolidFerryKit && swift test
