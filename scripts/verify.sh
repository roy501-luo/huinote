#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p .build/verification
swiftc -swift-version 5 -module-cache-path "$PWD/.build/ModuleCache" -I Sources/CSQLite -parse-as-library Sources/MeetingAssistant/BatchJob.swift Sources/MeetingAssistant/PlaybackTimeline.swift Sources/MeetingAssistant/Plaud.swift Sources/MeetingAssistant/Storage.swift Sources/MeetingAssistant/Audio.swift Sources/MeetingAssistant/PCM.swift Sources/MeetingAssistant/ASR.swift Sources/MeetingAssistant/PostMeeting.swift Sources/MeetingAssistant/MeetingMix.swift Sources/MeetingAssistant/MeetingQA.swift Verification/Verify.swift -o .build/verification/verify
.build/verification/verify
