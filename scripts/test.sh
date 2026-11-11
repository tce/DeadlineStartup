#!/bin/zsh
set -eu
cd "${0:A:h}/.."
mkdir -p .build/checks
swiftc -module-cache-path "$PWD/.build/clang-cache" Sources/DeadlineStartup/Deadline.swift Sources/DeadlineStartup/ConferenceImport.swift Sources/DeadlineStartup/BrowserLink.swift Sources/DeadlineStartup/ConferenceClipboard.swift Sources/DeadlineStartup/DeadlineFile.swift Sources/DeadlineStartup/DeadlineCalendar.swift Sources/DeadlineStartup/OverleafProject.swift Sources/DeadlineStartup/WritingSession.swift Tests/DeadlineStartupTests/DeadlineTests.swift -o .build/checks/deadline-tests
.build/checks/deadline-tests
