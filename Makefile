# Build and test OpenDente from the command line (VSCodium, SweetPad, CI), no Xcode IDE needed.
# Xcode.app must still be installed: xcodebuild and the macOS SDK come with it.
#
#   make generate   regenerate OpenDente.xcodeproj from project.yml, with your Team ID
#   make build      signed Debug build (needs .team-id)
#   make run        quit OpenDente and open the signed build (the helper only registers from it)
#   make test       unit tests, no signing needed
#   make clean      remove build output
#
# Your Team ID lives in .team-id (one line, git-ignored). `make team-id` prints it from your
# "Apple Development" certificate: it is the certificate's OU field. Not the ID in brackets in the
# certificate's name, which identifies the certificate, not the team.

TEAM_ID     := $(strip $(shell cat .team-id 2>/dev/null))
PROJECT     := OpenDente.xcodeproj
SCHEME      := OpenDente
DESTINATION := platform=macOS,arch=arm64
DERIVED     := build/DerivedData
# Tests build unsigned. Into DERIVED they would overwrite the signed app: macOS kills the
# running helper (its binary changed) and launchd refuses the unsigned one, leaving the
# firmware charge limit set with nothing to clear it.
# .noindex keeps Spotlight from offering this unsigned OpenDente.app.
TEST_DERIVED := build/TestDerivedData.noindex

.PHONY: generate build run test clean check-team team-id

# XcodeGen fills ${DEVELOPMENT_TEAM} in project.yml from the environment, so the generated
# project carries the real Team ID and SweetPad / plain xcodebuild sign with it.
generate:
	DEVELOPMENT_TEAM="$(if $(TEAM_ID),$(TEAM_ID),YOUR_TEAM_ID)" xcodegen generate --quiet

build: check-team generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination '$(DESTINATION)' -derivedDataPath $(DERIVED) \
		-allowProvisioningUpdates build
	@echo "Built: $(DERIVED)/Build/Products/Debug/OpenDente.app"

# Other copies named OpenDente.app (editor build server, tests) are ad-hoc or unsigned and
# can't register the helper, so open this one by path rather than through Spotlight.
run:
	-pkill -x OpenDente
	open "$(DERIVED)/Build/Products/Debug/OpenDente.app"

test: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination '$(DESTINATION)' -derivedDataPath $(TEST_DERIVED) \
		CODE_SIGNING_ALLOWED=NO test

clean:
	rm -rf $(DERIVED) $(TEST_DERIVED)

check-team:
	@test -n "$(TEAM_ID)" || { \
		echo "No Team ID. Run: make team-id > .team-id"; \
		exit 1; }

# The OU of the first "Apple Development" certificate in the keychain.
team-id:
	@security find-certificate -c "Apple Development" -p \
		| openssl x509 -noout -subject -nameopt multiline \
		| awk -F' = ' '/organizationalUnitName/ { print $$2 }'
