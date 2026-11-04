# Done! — Notification Scheduling Reference

_Last updated: 2026-11-04 (Goals added; slots now allocated by time, see §4 step 4 and §11)_

This is the reference for how Done! decides **which notifications fire, when, and for which
category**. Read it before changing anything in the scheduling code. Most past bugs came from
fixing one category in a way that quietly broke another (see [History](#7-history-of-bugs-and-fixes)).

---

## 0. Goals (check every change against these)

Agreed with Pat on 2026-11-04 after a run of fixes that each caused the next problem. Any
scheduling change must say which goal it serves and show it doesn't break a higher one.
In priority order (what gives way first when slots run out is at the bottom):

1. **Never miss a scheduled prompt.** Every scheduled occurrence (Day, Date or Time set) gets
   its on-time banner, even if the app isn't opened for a few days.
2. **A scheduled prompt due soon is properly noticeable.** In the next day or two it gets its
   full set of banners (run-ups / follow-ups, per the Banners per Reminder slider), not just
   one easy-to-miss banner. Day-only prompts especially, as their only on-time banner is the
   first allowed hour (7am).
3. **The feed stays balanced.** No category crowds out another, and the random feed keeps
   flowing alongside the scheduled ones.
4. **Respect what the user set.** A set time fires even in quiet hours; quiet hours hush
   the random feed and the extra nudges.

Fixes must be general (no one-off special cases for a category or rule shape) and come with
a test. If a fix only works by trading one goal for another, stop and revisit §11 instead.

---

## 1. The big picture

Done! has two kinds of prompts, planned by two schedulers that share one iOS limit:

| | **Scheduled prompts** | **Random prompts** ("Rolling Prompts") |
|---|---|---|
| What | Any prompt with a Day, Date or Time set in the Alert editor | Prompts with no Day/Date/Time (incl. bare "Once" to-dos) |
| Planned by | `ScheduledPromptScheduler.swift` | `RandomPromptScheduler.swift` |
| Notification ID prefix | `sched-` | `rand-` |
| Budget | What it needs, up to **50**; nice-to-haves only up to **40** (§4 step 4) | **60 − (sched pending)**, so ≥10, ≥20 on a normal day |
| Quiet hours | Primary alert ignores them, extras respect them | Fully respected |
| Plans how far ahead | Up to 35 days (repeating triggers cover forever) | Today only |

**The hard constraint:** iOS keeps at most **64 pending local notifications** per app. It keeps
the soonest-firing 64 and silently discards the rest (a repeating trigger counts as one). The app
caps itself at 60 combined to leave slack.

**There is no background refresh.** Nothing re-plans unless the app runs: it's opened or
foregrounded, a prompt or rule is edited, or Done/Skip is tapped on a banner. Everything has to be
queued with iOS ahead of time. That's why daily and weekly alerts use repeating triggers.

### Refresh pipeline

```
App opens / foregrounds (DoneApp)            ─┐
Prompt or rule edited (PromptsView, debounced) ├─► RandomPromptScheduler.refreshScheduleToday
In-app Done/Skip (PromptsView, StatsView)     ─┘        │  (serialised: a call made mid-refresh is
                                                         │   queued and runs next, never dropped)
                                                         ▼
                                     ScheduledPromptScheduler.refreshSchedule
                                       cancel all pending sched-* → plan → prioritise (≤50)
                                       → await every add (so the count below is accurate)
                                                         ▼
                                     RandomPromptScheduler.continueRefreshAfterScheduledPlanning
                                       budget = 60 − sched pending → plan today's rand-* slots
                                       (skipped if already planned today, unforced, and
                                        sched + rand still fits in 60)

Banner Done/Skip (PromptNotificationDelegate)
   record event → clearNotifications(prompt) → ScheduledPromptScheduler.requeueNextOccurrence
```

---

## 2. Files

| File | Role |
|---|---|
| `Done/PromptRules.swift` | `PromptRule` model, `recurrenceKind`, next/previous target maths, `cycleStart`, `PromptRulesStore` (`prompt_rules.json`) |
| `Done/ScheduledPromptScheduler.swift` | Scheduled planner (pure `planPrompt` / `plan` / `prioritised`) + iOS queuing + `requeueNextOccurrence` |
| `Done/RandomPromptScheduler.swift` | Random feed, `RandomPromptRules` (Settings → UserDefaults), `CategoryQuietWindow`, `CategoryRotation` (category fairness) |
| `Done/NotificationManager.swift` | `NotificationsManager`: `add` (awaitable), `clearNotifications`, `cancelPending`, 9pm summary, 8am morning update |
| `Done/PromptNotificationDelegate.swift` | Done!/Skip actions on banners, foreground presentation, suppressing banners already acted on today |
| `Done/PromptAlertEditor.swift` | Alert editor UI: produces every `PromptRule` shape (see §3) |
| `Done/PromptsView.swift` | Main lists, in-app Done/Skip (`markPrompt`), purge of completed one-offs, triggers re-plans |
| `Done/StatsView.swift` | Important prompts list, its own Done/Skip (`markImportantPrompt`) |
| `Done/DoneApp.swift` | Registers Settings defaults, plans on launch/foreground, deletes expired dated one-offs |
| `Done/Settings.bundle/*.plist` | Settings app → Done!: global earliest/latest hour, frequency slider, Rolling Prompts switch, per-category quiet windows |
| `Done/PromptSharing.swift`, `PromptImportSheet.swift` | Share/receive `.doneprompts` files. Imported prompts get fresh IDs and their rules are added through PromptsView's normal `rules` change → re-plan. Past dated Once prompts are skipped. |
| `DoneTests/DoneTests.swift` | Unit tests (Swift Testing) for all of the above |
| `Done/LockNudgeScheduler.swift` | **Dead code**, never called. Has its own hard-coded quiet hours. Don't wire up without fixing that. |

### Data files (app Documents folder)

| File | Contents |
|---|---|
| `prompts.json` | All prompt lists per category (`PromptsStore`) |
| `prompt_rules.json` | `[promptUUID: PromptRule]` |
| `prompt_actions.json` | Done/Skip events, **newest first**. A banner action's `occurredAt` is the banner's planned fire time, not the tap time (repeating triggers use delivery time). |
| `random_prompt_history.json` | Random feed: `lastPlanDate`, `pendingIDs`, `lastShown` |

---

## 3. Rule shapes: what the Alert editor produces

`recurrenceKind` priority: explicit Once → yearly (month+day) → monthly → fortnightly → weekly
(weekday) → dated one-off (date) → **daily** (time + Repeat) / one-off (time + Once) → none.

| Editor choice | Stored rule | `recurrenceKind` | Behaviour |
|---|---|---|---|
| nothing, Repeat | `{oneOff:false}` | `.none` | Random feed |
| nothing, Once | `{oneOff:true}` | `.oneOff` | **Random feed** (`hasSchedulingRule` false); purged the day after Done |
| Time, Repeat | time, `oneOff:false` | **`.daily`** (new 2026-11-03) | Every day at that time, repeating trigger |
| Time, Once | time, `oneOff:true` | `.oneOff` | Today at that time; nags if missed; purged after Done |
| Day, Repeat | weekday | `.weekly` | Every that weekday at first non-quiet hour, repeating trigger |
| Day + Time, Repeat | weekday + time | `.weekly` | Every that weekday at that time, repeating trigger |
| Day (± Time), Once | weekday, `oneOff:true` | `.oneOff` | Next that weekday only; purged after Done |
| Date, Once | date (± time) | `.oneOff` | That date, with lead-in days; deleted the day after the date |
| Date, Repeat, Yearly | date + month/day | `.yearly` | Every year, with lead-in days |
| Date, Repeat, Monthly | date + monthlyDay / lastDay | `.monthly` | 15th / last day each month, with lead-in days |
| Date, Repeat, Fortnightly | date + fortnightlyAnchorDate | `.fortnightly` | Every 14 days from the anchor, with lead-in days |

Notes:
- If Day and Date are both on, Date wins.
- A day-only rule's internal target is **23:59:59** on that day. That's for date maths only and
  never used as a fire time (it caused the old "weekday-only never fires" bug).
- `isImportant` (⭐️) is stored on the rule too. The editor must carry it over on save (it does).
- `repairCorruptedRules()` in PromptsView fixes `oneOff:true` + yearly/monthly/fortnightly
  fields. It deliberately leaves weekday + Once alone, because that's a legitimate combination.

---

## 4. How the scheduled planner works (`ScheduledPromptScheduler.planPrompt`)

A pure function: prompt + rule + Done/Skip events + `ScheduledPlanContext` (now, calendar, global
hours, category quiet windows, category of each prompt) → a list of `PlannedScheduledNotification`.
No iOS calls, so it's fully unit-tested.

### Step 1: occurrences
- Walk `rule.nextTarget(after:)` forward. Skip any occurrence already **settled** by a Done/Skip
  (an event at or after `rule.cycleStart(for: occurrence)`).
- Max occurrences: daily 3, weekly/fortnightly/monthly 2, yearly/one-off 1. Only within 35 days.
- **Missed one-off** (time or date passed, not settled): +15/+30 follow-ups if still ahead, then
  overdue nags starting **1h after planning**, every 3h, max 4 in 24h, quiet hours respected.
  The delay matters: planning runs on every in-app edit, so an immediate nag would fire constantly.
- **Recurring timed occurrence that passed under 30 min ago**, not settled: keeps its +15/+30
  follow-ups (it used to lose them when the target rolled to the next occurrence).

### Step 2: notification kinds per occurrence

| Kind | Timed prompt | Day-only prompt | Quiet hours |
|---|---|---|---|
| `primary` | At the set time | First non-quiet hour that day (global start, e.g. 7am; Work → 9am). If every hour is quiet (Work on a Saturday), the global start hour. | **Ignored** for a set time |
| `approach` | −30, −15 min | — | Respected |
| `followUp` | +15, +30 min | +4h, +8h, +12h after primary, same day | Respected |
| `leadIn` | Days before the **next** occurrence of a dated rule, at the rule's time (or first allowed hour if that's quiet) | Same, at first allowed hour | Respected |
| `overdue` | See step 1 | See step 1 | Respected |

**Banners per Reminder slider** (`banners_per_reminder`, 1–5, default 3) limits the extras per
occurrence via `extraOffsets(bannersPerReminder:)`. The primary always fires. Extras are added
closest-to-the-time first:

| Slider | Timed prompt | Day-only prompt | Missed one-off overdue nags |
|---|---|---|---|
| 1 | on time | first hour | none |
| 2 | −15, on time | + 4h | 1 |
| 3 (default) | −15, on time, +15 | + 4h, 8h | 2 |
| 4 | −30, −15, on time, +15 | + 4h, 8h, 12h | 3 |
| 5 | −30, −15, on time, +15, +30 | + 4h, 8h, 12h | 4 |

Lead-in days are **not** affected (they're one banner on each of several days, not repeats on the
day). Random prompts are always one banner each. `ScheduledPlanContext.bannersPerReminder` defaults
to 5 so the planner tests describe the full set unless they say otherwise.

Lead-in days (`leadInDays(for:)`): **yearly and dated one-off** → 30, 21, 14, 7, 6, 5, 4, 3, 2, 1
days before. **Monthly and fortnightly** → 5, 4, 3, 2, 1.

### Step 3: repeating triggers (daily and weekly)
If the next occurrence is **not** settled, the primary is one `UNCalendarNotificationTrigger`
with `repeats: true` (`{hour, minute}` daily, `{weekday, hour, minute}` weekly), ID
`sched-<uuid>-repeat`. It keeps firing even if the app is never opened again. Its userInfo has
**no** `prompt_date`, so a Done/Skip on it is recorded at delivery time.

If the next occurrence **is** settled (e.g. Friday's ticked off on Wednesday, or today's 8am done
at 7:30), a repeating trigger can't skip one date. So the following occurrences get one-off
primaries instead, and the next re-plan switches back to repeating.

### Step 4: slots by time (`prioritised`, rebuilt 2026-11-04, see §11)
**Needed**, may use up to `scheduledNotificationCap` (50):
0. Every **repeating** daily/weekly alert (one slot covers every future occurrence)
1. Every **one-off on-time alert within 7 days** (`guaranteedPrimaryHorizon`)
2. **One extra per prompt** due within 48h (`fullBannerHorizon`): its soonest run-up,
   follow-up or nag (not a lead-in day). This is what stops a day-only prompt being left with
   a single 7am banner.

**Nice to have**, only fills up to `scheduledSafetyNetCap` (40):
3. Remaining extras within 48h incl. lead-in days, shared fairly: every prompt's next extra
   before anyone's following one, then soonest first
4. On-time alerts more than 7 days away (re-planned on every app open long before they're due)
5. Everything else

Whatever scheduled leaves is the random feed's budget: ≥10 on a heavy day, ≥20 when only
nice-to-haves are filling. **Rule:** a near or repeating on-time alert is never cut; far-off
alerts and extra banners give way first.

---

## 5. Done / Skip flow

**From a banner** (`PromptNotificationDelegate.didReceive`):
1. Append event to `prompt_actions.json` (`occurredAt` = banner's `prompt_date`, else delivery time).
2. `await clearNotifications(forPromptID:)`: removes delivered banners and **all** pending
   requests for the prompt. It re-reads the pending list up to 3× so the removal is committed
   before iOS suspends the app.
3. `await requeueNextOccurrence(promptID:)`: re-plans just that prompt and re-adds up to 2
   primaries (the repeating trigger, or next one-offs). Without this, a daily/weekly prompt would
   go silent after any banner action until the app was next opened.

**In-app** (`PromptsView.markPrompt`, `StatsView.markImportantPrompt`): append event, then in one
Task `await clearNotifications` **then** run a full re-plan. The order matters: the re-plan queues
the next occurrence, and a still-running clear would delete it.

**Foreground safety net:** `willPresent` drops a banner for a prompt already acted on today.

**`cycleStart` semantics** (what a Done/Skip "settles"):
- daily: that day only
- weekly: anything from 6 days before the target day (marking it done early in the week counts)
- monthly/fortnightly: from 5 days before; yearly: from 30 days before
- dated one-off: from the start of today when ≤7 days away (so it comes back the next day until
  its date passes)

**Purging one-offs:** `PromptsView.purgeCompletedOneOffPrompts` removes undated one-offs done on a
previous day. `DoneApp.performOneOffCleanup` removes dated one-offs once the day after their date
begins. `oneOff == false` always protects a prompt from deletion.

---

## 6. Random feed essentials

- Window: today from max(now, global earliest) to global latest. Opened after latest → nothing today.
- Interval from the Notification Frequency slider: cold ≈ 60 min, default ≈ 20 min, hot ≈ 10 min.
  Widened automatically to spread a tight budget over the whole window (`planSlotTimes`).
- **Category fairness:** `CategoryRotation` round-robins categories, so a small or un-starred
  category (Health/Mindfulness) gets one slot per cycle. ⭐️ only weights picks *within* a category.
- Category quiet windows skip that category for a slot. Prompts acted on today are excluded.
- Planned once per day unless forced (prompt/rule edits and Settings changes force it), or unless
  sched + rand would overflow 60.
- Rolling Prompts switch off → cancels pending `rand-*` only. Scheduled prompts still fire.

### Settings (Settings app → Done!), registered in `DoneApp.init`
`random_prompts_enabled` (true), `notification_intensity` (0.5), `banners_per_reminder` (3; read via
`RandomPromptRules.bannersPerReminder` and passed to the scheduled planner), `global_earliest_hour` (7),
`global_latest_hour` (20), `quiet_<category>_start/_end/_weekends`. Only **Work** has non-zero
defaults: 17 → 9 plus weekends. Category keys: daily, weekly, work, monthly, yearly, events,
study, mentalhealth (displayed as "Health"). Defaults in `DoneApp.init` must match the plists by hand.

The 9pm summary and 8am "done yesterday" update are skipped if their hour falls in global quiet hours.

---

## 7. History of bugs and fixes

| Date | Symptom | Cause | Fix |
|---|---|---|---|
| 2026-07-09/14 | Notifications during quiet hours | Scheduled prompts and 9pm/8am summaries ignored quiet hours | Quiet-hour filtering added everywhere (later refined: a set time now overrides, see 11-03) |
| 2026-08-16 | Mindfulness/Health prompts disappeared | Random feed did one flat draw across all categories | `CategoryRotation` round-robin |
| 2026-08-24/26 | Repeating reminders stopped | (1) auto-delete ignored Repeat; (2) day-only weekly fired at 23:59 and got quiet-filtered; (3) daily bare-time went dark if missed by 30 min | Repeat always wins; anchor to day start; roll forward (now replaced by `.daily`) |
| 2026-10-03 | Random feed silent for weeks | 15 daily meds × 4 nudges + 50-slot birthday ramps filled all 60 slots | Sched cap 40; random slots spread over the day |
| 2026-10-22 | 3pm appointment's 2:30/2:45 nudges missing | Soonest-first trim let overdue nags win | Approach nudges prioritised; on-time nudge added |
| 2026-10-25 | Prompts re-fired after Done/Skip | Removal not committed before iOS suspended the app | `clearNotifications` re-reads until gone; `willPresent` filter |
| 2026-10-31 | Whole Work list missing from random feed | Bare "Once" counted as scheduled | `hasSchedulingRule` false for bare Once |
| 2026-11-03 | (feature) Too many banners per prompt, no control | Fixed 5-banner pattern | Banners per Reminder slider (see §4 step 2); **default 3 is fewer than the old 5** |
| **2026-11-03** | Fixing one category kept breaking another; weekly Friday reminders unreliable | Special cases piling up; see list below | **Planner rewrite** (this document) |
| **2026-11-04** | Mop / Wipe out microwave (day-only weekly) silent since 22 Oct, then only one 7am banner | Slots handed out by kind, not time: on-time alerts up to 2 weeks away filled all 40, no extras survived | **Slots by time** (§4 step 4, §11); sched cap 50 needed / 40 nice-to-have |

### What the 2026-11-03 rewrite fixed
- A set time inside quiet hours was silently dropped: weekly 9pm bin night, Work reminders at or
  after 5pm or on weekends. → Primary ignores quiet hours.
- Daily reminders were queued only 24h ahead, so they needed the app opened every day. → Repeating trigger.
- Date-only prompts ramped toward 23:59 (at night, quiet-filtered); thinning to 7 could leave
  nothing on the day itself. → Explicit primary + follow-ups on the day.
- "Once on Friday" with no time nagged all week. → Fires on Friday only.
- One yearly prompt could take 50 slots. → Fixed lead-in day list; extras rank below all primaries.
- Done/Skip on a banner wiped later occurrences. → `requeueNextOccurrence`.
- A refresh requested mid-refresh was dropped; the random plan could overflow 64 when sched grew. → Queued; overflow triggers a rebuild.
- Sched adds were fire-and-forget, so the random budget read a stale count. → Awaited adds.
- Unreadable `prompt_rules.json` wiped every scheduled notification. → Leaves the queue alone.
- In-app Done/Skip raced its clear against the re-plan. → Sequenced.

Behaviour changes worth remembering: day-only prompts now remind ~4× on the day (7/11/3/7);
birthday lead-in is 30/21/14 then daily for the last week (was a daily 30-day ramp); missed
one-offs first nag after 1h (was instant on every refresh).

---

## 8. Rules of thumb for future changes

1. **Never add a special case for one category or rule shape inside the planner.** Express it as
   occurrences + kinds + tiers, and add a test that pins the case down.
2. **Repeating and next-7-day on-time alerts must always survive the cap**, plus one extra per
   prompt due in 48h. If the budget is tight, cut the nice-to-haves (§4 step 4).
3. **A time the user set is sacred.** Quiet hours govern the random feed and nags, not explicit times.
4. **Anything that removes pending requests for a prompt must be followed by re-queuing** its next
   occurrence (`requeueNextOccurrence` or a full re-plan), and must finish before the re-plan starts.
5. **Keep sched ≤ 50 (nice-to-haves ≤ 40) and the combined total ≤ 60.** iOS silently discards beyond 64.
6. Every planner change gets a test in `DoneTests.swift`, using the fixed "now" (Wed 4 Nov 2026,
   10:00) helpers, never `Date()`.
7. Users treat "Once" as "delete when done", not as a schedule (see the 10-31 fix). Two inline
   Once/Repeat-on-add designs were rejected (2026-10-22). Don't re-propose them.

---

## 9. Debugging and testing

### Unit tests
```bash
cd ~/Developer/Done
xcodebuild test -scheme Done \
  -destination 'platform=iOS Simulator,id=41CA53CB-CAAA-4669-8A7D-7ECFD28A2204' \
  -only-testing:DoneTests
```
(Destination by simulator **id** for iPhone 16 Pro. Using `name=` failed on this machine.
`xcrun simctl list devices available` lists the ids.) 42 tests as of 2026-11-04.

### Debug console
DEBUG builds log every planned notification: `SPS:   primary 'Bins' at … (repeating)`, plus
`RPS:` lines for the random budget and plan. Run from Xcode with the phone attached to see them.

### Pulling real data off the iPhone
```bash
xcrun devicectl list devices
xcrun devicectl device copy from --device <devicectl-id> \
  --domain-type appDataContainer --domain-identifier patsarell-gmail.com.Done \
  --source Documents --destination ./device-data
```
Check `prompt_rules.json` (is the rule shape what the user meant?), `prompt_actions.json` (did a
Done/Skip settle the occurrence?), and `random_prompt_history.json` (is the random feed planning at all?).

### "I didn't get prompt X": checklist
1. Scheduled or random? Look up its rule. No day/date/time (or bare Once) means random.
2. **Scheduled:** does the rule shape (§3) match what they intended? Was the occurrence settled by
   an event after `cycleStart`? Did a primary make the cap (it always should)? Day-only: what was
   the first non-quiet hour for that category?
3. **Random:** is Rolling Prompts on? Is that category's quiet window covering the whole day? What's
   the random budget (60 − sched)? Was the app opened that day (random plans today only)?

### On-device test checklist (set times a few minutes ahead)
- Daily Repeat: −30/−15, on time, and **tomorrow without opening the app**
- Done on the −15 nudge: nothing more today, tomorrow still arrives
- Weekly on today's day: arrives today and next week
- A reminder after the latest hour (9pm) or a Work one after 5pm: the primary fires
- Day-only tomorrow: 7am (Work 9am), then 11am/3pm/7pm, nothing today
- Random feed still flowing between scheduled ones

---

## 10. Known limits and open ideas
- **No background refresh** (`BGAppRefreshTask`). The random feed only plans the day the app is
  opened. Scheduled one-offs beyond the repeating triggers refill on open.
- Weekly `cycleStart` starts 6 days before the target, so an in-app Done on **Saturday** for a
  missed Friday counts toward *next* Friday. Banner actions are fine (recorded at fire time).
- A repeating trigger can't skip a single date, which is handled by the one-off fallback in §4 step 3.
- Time-Sensitive notifications (to break through Focus for ⭐️ prompts) are available now that
  the paid Developer Program is active (2026-09-02), but not implemented.
- `LockNudgeScheduler` is dead code.

---

## 11. Open: slot-allocation redesign (started 2026-11-04)

**Status:** built 2026-11-04 (`prioritised` + tests). **Needs device test.** On Pat's 2026-11-04
data: 0 on-time alerts in the next week dropped; Mop and Wipe out microwave get 7am + 11am;
random budget 10–11 during exam season (18 repeats + 15–17 dated alerts + 15 needed extras).
**Intended (Pat, 2026-11-04):** a thinner random feed on heavy weeks is right: "on heavy weeks
less focus is on random stuff." Don't treat it as a bug. If it ever feels too thin, raise the
floor (lower `scheduledNotificationCap`) rather than re-tuning tiers.

### Why
The fixes in §7 each re-tuned *who gets the slots* for whatever was missed that week, and the
next problem surfaced somewhere else. The real constraint never changed: ~64 iOS slots and no
re-planning unless the app is opened. The planner hands out slots **by kind** (primaries,
then extras) with **no regard to time**, so slots go to things weeks away while today's
banners are dropped.

### Evidence (device data and live log, 2026-11-04)
- Mop (Thu), Wipe out microwave (Wed), Toilet (Mon), Vacuum (Tue): day-only weekly to-dos with
  a Done/Skip every week until 21–22 Oct, then silent. Cause on the pre-rewrite build (before
  99926ff): run-up nudges claimed slots first and the rest went soonest first, so day-only
  prompts (no run-ups) came last and were cut.
- On the current build: 346 sched requests planned, **all 40 kept are primaries**, reaching
  out to 16 Nov. Zero extras queued for anything, so the Banners per Reminder slider has no
  effect, and Mop / Wipe out microwave get only a single 7am banner (11am/3pm follow-ups cut).
- Each weekly repeat sits ~7 days out right after its day, near the bottom of the 40. A few
  more dated items and it would be cut until the next re-plan (goal 1 at risk).
- A daily prompt already done today takes 3 one-off slots (e.g. Ritalin – Morning) instead of 1.

### New approach: allocate by time, scheduled sets the random budget
"Slots" means iOS's pending queue (what's waiting to fire right now), not a per-day count.
A weekly prompt like Mop is **one** repeating entry that sits in the queue all week and fires
only on Thursday. It doesn't take a slot on each day, but while it waits it's one fewer slot
for everything else, including today's random feed. ~25 daily/weekly repeats → ~25 slots
permanently taken, which is the cheapest way to guarantee goal 1. The squeeze comes from
one-off items weeks away, which under this plan only take a slot once they're near.

Plan the queue as one whole, in this order:

1. **Repeating triggers** for every daily/weekly prompt (one slot each, cover forever).
2. **On-time banners for one-off occurrences in the next ~7 days** (dated, monthly, yearly,
   fortnightly, Once).
3. **Full banner set for anything due in the next 24–48h** (run-ups, follow-ups, day-only
   follow-ups, overdue nags, lead-in banners for those days).
4. **Thin safety net beyond that:** further-out on-time banners only if slots remain. They're
   re-planned on every app open long before they're due.
5. **Random feed gets what's left today** — i.e. the scheduled prompts define how many random
   prompts you can get that day. Busy scheduled day → fewer random; quiet day → more.

Open decisions:
- **Random floor?** With "random gets what's left", a heavy scheduled day could starve the feed
  (the 2026-10-03 bug). Time-based allocation should keep scheduled demand far lower than today's
  40, but decide whether to keep a minimum (e.g. 10/day) for random as a backstop.
- **Horizons:** exact values for "full banners" (24h vs 48h) and "on-time" (7 days).
- **Replaces the fixed 40 cap** and rule-of-thumb 2 in §8 ("primaries always survive") becomes
  "near primaries and repeats always survive". Update §1, §4 step 4 and §8 when built.
- ~~Daily prompt done today: fall back to 1 one-off, not 3.~~ Rejected: the 3 cover the app not
  being opened for a few days (goal 1). Under §4 step 4 they're cheap anyway.
- Decided: random floor 10 (60 − 50), full-banner horizon 48h, on-time horizon 7 days.

### Before building
1. Count real demand from device data under the new tiers (how many slots does a typical day
   need?) to settle the horizons and the floor.
2. Write tests first, one per goal, using the 2026-11-04 device data shape (Mop/Wipe out
   microwave getting follow-ups; weekly repeat never cut; random never below the floor).
3. Device test: Mop Thu and Wipe out microwave Wed get 7am + follow-ups; random still flowing.
