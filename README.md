# Deadline Startup

A native macOS 13+ application that shows upcoming deadlines at login, earliest first. A standalone app is appropriate because it owns its window, local data, and login lifecycle. An extension depends on a host or a particular system extension point and adds unnecessary complexity here.

## Run

Version 1.1 adds reminders after wake. Quit any older running copy, replace it with the new bundle, and reopen it.

The ready-to-open app is `build/Deadline Startup.app`. Move it to Applications for a stable installation, open it, then turn on **Open at login**. If macOS requires approval, use the in-app System Settings button. Login registration uses Apple's `SMAppService.mainApp`; the system remains in control of approval. Do not move the app after enabling login without disabling and re-enabling the setting.

Add deadlines with a date, name, type, and optional HTTP/HTTPS link. Abstract, Paper, Review, and Letter are supplied; choose “Add a custom event type” to save additional types. Click the link icon to open the event in your default browser. Edit from the pencil; mark complete or delete from the row menu. Upcoming includes today and all future dates; “Include past & completed” shows the full history. Dates are local calendar dates without time-of-day reminders.

Escape, the upper-right X, and the standard window close button dismiss the reminder window. A small menu-bar listener stays running so reminders can reappear after system sleep, display sleep, or returning to your user session. The menu-bar calendar offers **Show Deadlines** and **Quit Deadline Startup**. Command-Q also fully quits; after quitting, wake reminders resume only when the app is opened again. Escape in the editor cancels editing.

Enable **Open at login** to start the listener automatically after a restart or logout. Waking and unlocking an existing session does not trigger a login item, so wake notifications are handled separately. Reminders refresh their date and ordering when the window returns. This app does not send background notifications.

Data is saved in `iCloud Drive/DeadlineStartup/deadlines.json` when iCloud Drive is present; the file is created if it does not exist. If iCloud Drive still holds the file only as an undownloaded placeholder, the app starts the download and waits rather than creating an empty file over it. Macs without an iCloud Drive folder use the hidden `~/.deadlinestartup/deadlines.json`, also created if missing. An existing `~/Library/Application Support/DeadlineStartup/deadlines.json` from earlier versions is copied there on first launch and left in place as a backup. No account or network service is required. Event URLs open only when clicked. An unreadable data file is preserved rather than overwritten.

## Build and verify

Requires Apple's command-line tools with a Swift 6 compiler; full Xcode is not required.

```sh
./scripts/build-app.sh
./scripts/test.sh
```

The build script creates a locally ad-hoc signed app bundle. Distribution to other Macs requires Developer ID signing and notarization. Login behavior should be verified after moving the app to Applications and logging out/in; compilation and model tests cannot establish system login approval.


## Rich deadline details (1.2)

The due date stays on the left. Each reminder includes its title and website globe, full event name, event dates, location, notes, and type. Optional fields stay hidden until filled in through the editor. Existing deadline files remain compatible.

Enable “Specify deadline time” for an exact time and a live seconds countdown. The time-zone field accepts identifiers such as America/New_York or Etc/GMT+12 (UTC−12). Without a time, deadlines remain date-only and show a days countdown rather than implying a precise cutoff. “Add to calendar…” exports an iCalendar (.ics) file that can be opened in Apple Calendar or imported into Google Calendar, Outlook, or Yahoo.


## Import from a conference website (1.3)

Drag a conference URL from your browser address bar or a web link anywhere in the main application window. The window highlights while a link is dragged over it. The app reads the page and up to three linked call-for-papers/important-dates pages, then presents deadline candidates with their original text and source links. Choose the abstract, paper, review, or letter deadline to track, review the editable details, and save. No import is saved automatically.

The importer runs locally using HTML text and Schema.org Event metadata; it does not require an AI account or send page contents to an AI service. It extracts explicit-year submission dates and structured/labeled event names, dates, locations, and topics. Missing fields remain editable. If no date is found, saving requires setting the due date manually. A precise countdown is enabled only when both a time and an explicit UTC/GMT offset or AoE zone are recognized; otherwise review the source and set the time/zone yourself.

Pages requiring JavaScript, authentication, CAPTCHA, PDF parsing, or unusual layouts may not import fully. Use a direct HTML call-for-papers page or enter missing details manually. Websites are contacted only for an import and linked source pages; requests use an ephemeral session. Requests have time and size limits; canceling the import cancels the task.

The HAIC 2027 home URL (`https://haic.cc/#/home`) is covered by an import regression check: Abstract on January 21, 2027 and Paper on January 28, 2027, with event dates June 27–30 and Washington, DC. Undated “to be announced” entries and review/rebuttal/notification dates are excluded. Re-importing a matching conference, date, and type opens the existing reminder for review instead of creating a duplicate.


Version 1.4 makes the entire main window a conference URL drop target and removes the paste button. Topics are no longer shown in reminders or the editor; existing stored topic data remains compatible.

Version 1.5 supports browser HTML anchors (including linked globe images), Markdown links, and URL/title text drags. When multiple representations are available, the conference anchor destination is preferred over the image source. Image-only URLs such as `http://aideadlines.org/static/img/203-earth.svg` cannot identify a conference and produce a specific explanation rather than attempting CFP extraction from an icon.


Version 1.7 adds URL paste import: copy a conference website URL, activate the main reminder window, and press Command-V (or Edit → Import Conference URL from Clipboard). Pasted URLs and formatted links use the same parsing and review flow as dropped links. Paste into editor text fields continues to edit their text.


Version 1.8 fixes Command-V with no text field focused by handling the shortcut at the native window level. Text inputs and sheets keep their normal paste handling. Verified in the running app: pasting the HAIC URL opens import review with January 21 and January 28, 2027; the test was canceled without saving. Clipboard tests use a separately named pasteboard and require access to the macOS pasteboard service.


Version 1.9 supports selecting multiple imported deadlines with checkboxes, Select all, and Clear. Review each selected deadline in sequence, then save the entire batch on the final screen. Cancel discards the pending batch. Existing matching reminders are updated rather than duplicated. The batch-save logic is tested, and the running app was checked for selecting both HAIC deadlines and opening batch review.


## Shared data in iCloud Drive (2.0)

Use this version of Deadline Startup on each Mac, signed into the same Apple Account with iCloud Drive enabled. In Finder, ensure `iCloud Drive/DeadlineStartup/deadlines.json` is downloaded, then open the app. It loads that same relative path on every Mac and shows “iCloud Drive” in its footer. The app reloads when activated or reopened after wake. Login settings remain specific to each Mac.

File access is coordinated with macOS and runs off the main thread. Saves compare the loaded file contents before replacing the file, so updates already received from another Mac are not silently overwritten. If the file changed, the app loads the latest data and asks you to reopen the editor. Let iCloud finish syncing before switching computers; this is a shared document rather than a real-time database, and simultaneous offline edits can still produce iCloud conflicts. Unreadable or not-yet-downloaded shared files are preserved rather than replaced with an empty file or an older local copy.

On November 11, 2026, four existing deadlines were copied into the iCloud Drive file on this Mac. The original local file remains as a backup. iCloud Drive handles transfer to the other Macs; installing the application on those computers is still required.


## Paper details and actions (2.1)

Click the body of a deadline row to open its own details window. The **about** column has a multiline text area for describing the paper. The **actions** column has editable tasks, completion checkboxes, an add field, and remove buttons. Each deadline has its own text and tasks.

Use **Save** or Command-S to save to the same shared iCloud file. Closing a window with unsaved edits offers Save, Cancel, and Discard Changes. Quitting warns about unsaved details. Website, calendar, pencil, and row-menu controls keep their existing functions. Re-importing or editing conference details preserves the about text and actions. Older deadline files load with these new fields empty.


Version 2.2 shares about text and actions across all deadlines for the same conference edition. Saving from any details window updates every matching date, including task completion. Newly added/imported dates inherit existing conference details. On opening older data, missing shared details are filled in; distinct existing descriptions and task IDs are retained and combined. Deadline dates, types, and completed-deadline status remain independent. Different named years are kept separate. Unedited open details windows refresh after another window saves; a window with unsaved edits retains its draft and detects conflicting saves.


Version 2.3 includes a custom typewriter-and-finish-line icon, generated with the built-in image tool. Source artwork and prompt are in Assets/AppIcon.png and Assets/AppIcon-prompt.txt. Assets/AppIcon.icns contains the Mac icon sizes. The build copies the icon into the app bundle.


Version 2.4 raises the reminder window above ordinary app windows after wake, unhides and activates the app, and explicitly orders it to the front after activation. Wake reminders can appear across desktop spaces, including alongside fullscreen apps. Dismissing the reminder or opening a paper-details window restores normal window priority. macOS security screens remain under system control; verify the wake/unlock sequence on the target Mac.

Version 2.5 fixes blank startup windows by opening paper details as explicit, non-restored native windows instead of a secondary SwiftUI launch scene with an optional deadline ID. Verified two launches in the running app, including quitting with a details window open: the reminder list appears with all four iCloud deadlines. Row clicks still open the populated about/actions window.


Version 2.6 presents the reminder in front after wake at normal window level. It does not remain floating or join every desktop; selecting another application can bring that app to the front. The activation follow-up also checks that Deadline Startup is still active before raising its window again.


Version 2.7 handles the screen-unlock broadcast in addition to workspace wake events, since waking may happen while the login screen is still present. Presentation uses a bounded temporary window-level boost while waiting for the actual application activation callback. Normal priority is restored when activation finishes, when another app is selected, when dismissed, and after a 0.75-second fallback timeout. The macOS screen lock/unlock distributed notifications supplement the documented workspace notifications. A real sleep/unlock cycle must be checked on the target Mac.

Version 2.8 adds a centered calendar grid on the header separator, covering twelve months starting with the current month. Columns are weeks and rows are weekdays, with month headings and Monday/Wednesday/Friday labels. Active deadline days have black-and-white finish-flag checkerboards; today has an accent outline. Hover a day for its date and deadline names/types. The calendar updates as time passes and after deadline changes. Date-range, leap-year, week-alignment, and multiple-deadlines-per-day checks pass; the running layout was visually inspected with all four deadlines marked.


## Overleaf projects (3.0)

The two-column details window has an **Open Overleaf** button. Its adjacent menu can link an existing project's `https://www.overleaf.com/project/<id>` editor URL. The association is saved in iCloud and shared across that conference's deadlines; importing/editing reminders preserves it.

Without a saved link, the button opens an Overleaf browser window. Sign in there if prompted; this window uses a persistent browser session separate from your default browser. On the project dashboard, the app looks for an exact conference-name match among the projects displayed. A unique match is opened and linked; multiple matches are left for you to choose. Otherwise, it imports the configured GitHub template ZIP through Overleaf's documented `/docs` import form and captures the resulting editor URL automatically. If the dashboard cannot be identified, use **Create template project** or open an existing project to link it. A saved editor URL returning HTTP 404 triggers replacement creation; authentication/access errors do not, because lack of access does not mean a project is absent.

The configured public GitHub ZIP URL and conference title are sent to Overleaf for project creation. About text and actions are not included. The app does not have an account-wide project search API; link a differently named or undisplayed existing project first to avoid creating another. Signing in and authenticated project creation require verification with your Overleaf account; automated checks cover URL validation, LaTeX escaping, import request encoding, and association sharing without creating an online project.

Overleaf import documentation: https://www.overleaf.com/devs


## Overleaf time and writing days (3.1)

Each new in-app Overleaf window counts as one project opening; bringing an existing window forward does not count again. Elapsed wall-clock time runs while the window remains open, including when in the background or minimized, and stops on close. Descriptions and task windows show the conference/project's total opening count and elapsed time, updated live. Regular app quit flushes the latest session time before exiting. Sessions are checkpointed to iCloud every ten seconds and at close; a forced termination can lose the last few seconds and does not leave a clock running after restart.

A session longer than 60 seconds turns the calendar square for its opening date green. This uses the local day at opening, including for sessions crossing midnight. Several sub-minute sessions do not individually qualify. Green takes precedence if a day also has a deadline. Statistics use stable session IDs so live checkpoints and synced records are not counted twice. They are shared across deadlines for the same conference or linked project. Only the app's Overleaf window is measured; windows opened separately in your browser are not tracked. Opening/sign-in time and time during sleep count because the window remains open.


## Local projects in Emacs, TeXShop, VS Code, and other editors

In a deadline’s details window, open the menu beside **Open Overleaf** and choose **Create local project in**, then the application to use: Emacs, or any installed TeXShop, TeXstudio, Visual Studio Code, Cursor, Zed, Sublime Text, or BBEdit, or **Other application…** for any app. Choose a parent directory (the app remembers it between launches). The app downloads https://github.com/tce/LatexPaperTemplate/archive/HEAD.zip, extracts the complete repository into a new folder named after the conference, saves its location across the conference’s deadlines, and opens it in the chosen application (Emacs gets a dedicated frame; VS Code, Cursor, Zed, and Sublime Text get the project folder; other apps get the main LaTeX document). If that folder name already exists, a numbered suffix prevents overwriting it. Template filenames and supporting files are preserved. Creation requires access to GitHub; reopening an existing project uses its local files without downloading again. Future clicks use **Open in <application>**. To switch applications later, choose **Open local project in** from the same menu; the choice is saved in iCloud and shared across the conference’s deadlines. Projects created before this option continue to open in Emacs. Overleaf remains available in the menu.

Every application counts toward the conference’s openings and time, and the details window shows a per-application breakdown (for example “TeXShop: 3 openings, 1h 10m 00s”). Emacs time runs while the project frame is open. Other applications cannot report when one project is closed, so their time counts only while that application is the active (frontmost) app, pausing when you switch away, lock the screen, or the Mac sleeps, and the session ends when the application quits. Reopening a project already open in the same running application brings it forward without counting another opening.

In the reminder list, each deadline shows its opening count and total time worked under the date (hover for exact seconds). Beside the Paper/Abstract tag, a tag appears for each project created or linked for the deadline (the local project’s application, such as **TeXShop**, and **Overleaf**); click a tag to open that project. Clicking a tag counts as an opening just like the details window buttons.

Emacs and `emacsclient` are detected in Emacs.app in Applications, Homebrew, or PATH. An Emacs server is started automatically if necessary. Each new project frame counts as one opening; bringing an already tracked frame forward does not add another. The existing live totals, ten-second checkpoints, quit saving, and green writing days include these sessions. Close the client frame or finish with `C-x #` to stop its timer. Background and minimized time counts, just as with Overleaf. Deadline Startup must remain running to track time; independently opened Emacs files are not tracked. The saved path refers to this computer; the source files themselves are not uploaded by the app.


The Emacs launcher prepares the running session for LaTeX outline hooks: outline setup preserves the current source buffer, and `my-project-hook` is skipped for buffers without filenames. This avoids a `Wrong type argument: stringp, nil` error when an outline hook selects a temporary buffer before subsequent file hooks run. These guards do not edit your Emacs configuration files. Run `./scripts/test-emacs.sh` for the Emacs regression checks (`EMACS_BINARY` can override the executable).


## Project settings and launch progress

Open **Deadline Startup → Settings…** (`⌘,`) to change the public GitHub template repository used for both local and Overleaf creation. The default is `https://github.com/tce/LatexPaperTemplate`. Save the repository URL to keep it between launches. Settings also lets you choose the remembered parent directory for local projects. Changes apply to new projects; existing local files and linked Overleaf projects are reopened as usual.

Each launch displays a progress dialog with the current step and a final success or error message. Local creation reports downloading, ZIP checks, extraction, document selection, saving, and Emacs startup. Overleaf reports loading, sign-in, existing-project lookup, template import, and saving the project link. Choose **Hide progress** when you need to interact with the Overleaf sign-in window; hiding the dialog does not cancel the launch. The dialog uses an indeterminate indicator because Overleaf does not provide a reliable completion percentage. Time and opening counts continue to use the existing session tracker.


Emacs readiness uses a dedicated project frame parameter rather than the visible frame name, and tolerates emacsclient status banners. Slow startup no longer terminates the client after ten seconds. If Emacs is waiting for a prompt, the progress dialog asks you to check its window while the connection remains open. Connection errors distinguish an exit code from termination by a signal.


On macOS the launcher explicitly requests `emacsclient --create-frame --display ns` with `(window-system . ns)`. It checks that the connected server supports the native macOS backend and only accepts a graphical project frame as ready. A terminal-only server produces an explanatory error rather than being treated as a successful graphical launch.
