# Done! — notes for Claude

- **Before touching notifications or scheduling** (`ScheduledPromptScheduler`, `RandomPromptScheduler`,
  `PromptRules`, `NotificationManager`, `PromptNotificationDelegate`, Done/Skip handling), read
  `docs/NOTIFICATION_SCHEDULING.md`. It covers how all categories share the 64-notification limit,
  the priority rules, the bug history, and how to test. Update it when the behaviour changes.
- Unit tests: `xcodebuild test -scheme Done -destination 'platform=iOS Simulator,id=41CA53CB-CAAA-4669-8A7D-7ECFD28A2204' -only-testing:DoneTests`
- The app is in testing mode: treat new asks as bugs or polish unless clearly framed as a feature.
