#!/bin/zsh
set -eu
cd "${0:A:h}/.."
EMACS_BINARY=${EMACS_BINARY:-/Applications/Emacs.app/Contents/MacOS/Emacs}
mkdir -p .build/checks
swiftc -module-cache-path "$PWD/.build/clang-cache" Sources/DeadlineStartup/EmacsIntegration.swift Tests/DeadlineStartupTests/EmacsIntegrationEmitter.swift -o .build/checks/emit-emacs-integration
.build/checks/emit-emacs-integration > .build/checks/emacs-integration.el
DEADLINE_EMACS_PREPARE_FILE="$PWD/.build/checks/emacs-integration.el" "$EMACS_BINARY" --batch -Q -l Tests/DeadlineStartupTests/EmacsIntegrationTests.el
