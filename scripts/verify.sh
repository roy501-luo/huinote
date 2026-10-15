#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p .build/verification
swiftc -swift-version 5 -module-cache-path "$PWD/.build/ModuleCache" -I Sources/CSQLite -parse-as-library Sources/MeetingAssistant/BatchJob.swift Sources/MeetingAssistant/PlaybackTimeline.swift Sources/MeetingAssistant/Plaud.swift Sources/MeetingAssistant/Storage.swift Sources/MeetingAssistant/Audio.swift Sources/MeetingAssistant/PCM.swift Sources/MeetingAssistant/ASR.swift Sources/MeetingAssistant/LiveASR.swift Sources/MeetingAssistant/PostMeeting.swift Sources/MeetingAssistant/MeetingMix.swift Sources/MeetingAssistant/MediaImport.swift Sources/MeetingAssistant/MeetingQA.swift Sources/MeetingAssistant/MeetingKeywords.swift Verification/Verify.swift Verification/VerifyLiveASR.swift -o .build/verification/verify
.build/verification/verify
swiftc -swift-version 5 -module-cache-path "$PWD/.build/ModuleCache" -parse-as-library Sources/MeetingAssistant/NoteComposer.swift Verification/VerifyNoteEditor.swift -o .build/verification/note-editor
.build/verification/note-editor
