# Done! — notes for Claude

## Notification goals (agreed 2026-11-04, apply to every scheduling change)

In priority order; what gives way when the ~64 iOS slots run out is at the bottom:

1. **Never miss a scheduled prompt.** Every Day/Date/Time occurrence gets its on-time banner,
   even if the app isn't opened for a few days.
2. **Scheduled prompts due soon are properly noticeable**: full banner set in the next day or two,
   not one easy-to-miss banner (day-only prompts especially).
3. **The feed stays balanced**: no category crowds out another; the random feed keeps flowing.
   Scheduled prompts define how many random prompts fit in a day.
4. **A set time is respected**, even in quiet hours.

**Don't patch priorities or caps one bug at a time.** That's what kept creating new problems.
The agreed fix is the time-based slot-allocation redesign in `docs/NOTIFICATION_SCHEDULING.md`
§11 (built 2026-11-04, see §4 step 4; needs device test). Any scheduling bug should be fixed by advancing that plan, or by a
change you can show serves a goal above without breaking a higher one. If a fix trades one goal
for another, stop and raise it with Pat. Keep §0 and §11 of the doc current.

- **Before touching notifications or scheduling** (`ScheduledPromptScheduler`, `RandomPromptScheduler`,
  `PromptRules`, `NotificationManager`, `PromptNotificationDelegate`, Done/Skip handling), read
  `docs/NOTIFICATION_SCHEDULING.md`. It covers how all categories share the 64-notification limit,
  the priority rules, the bug history, and how to test. Update it when the behaviour changes.
- Unit tests: `xcodebuild test -scheme Done -destination 'platform=iOS Simulator,id=41CA53CB-CAAA-4669-8A7D-7ECFD28A2204' -only-testing:DoneTests`
- The app is in testing mode: treat new asks as bugs or polish unless clearly framed as a feature.
