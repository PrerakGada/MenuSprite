# Report a Problem and Send Feedback

Added in 0.5.9 at Prerak's request (2 October 2026): every app he ships has these two entry points, and
they all post to one shared endpoint, `POST https://api.prerakgada.in/v1/p/menusprite/feedback`.

## Where

The hub's **Tools** tab opens with a **Help & feedback** card holding **Report a Problem…** and
**Send Feedback…**, first so it is seen without scrolling. MenuSprite has no status-item menu, Help menu
or Settings window to put them in. The hub reopens on the last tab used, so no tab is a fixed front page;
the top of System would sit above the readings on every daily open.
Both open one small window (`FeedbackWindow.swift`); Report a Problem… chooses *Problem*, Send Feedback…
chooses *Idea*. It is an ordinary titled window, because typing needs a key window and the hub is a
non-activating panel. While it is open MenuSprite has a Dock icon, as it does for the main window.

The window, top to bottom: Problem / Idea / Other feedback; the message; optional name and email; the
line "Sent with your message: MenuSprite 0.5.9 (20) · macOS … · Mac…"; the footnote "Goes straight to
Prerak, who makes MenuSprite. Nothing is sent until you press Send."; Cancel and Send. Send needs three
characters that are not spaces. **⌘↩ sends** (plain Return starts a new line in the message), Esc and
⌘W close. A sent message replaces the form with "Thanks, it's sent."; a failure keeps everything typed
and shows the server's sentence for a 400 or 429, otherwise "Couldn't send. Check your connection and try
again." Only a 2xx counts as sent. There is one attempt, 15 seconds at most, and closing the window
cancels it.

## What is sent

Only the message, the optional name and email, and app version, build, platform, macOS version and
`hw.model` (`ProductFeedback/ProductFeedback.swift`, `FeedbackContext`). The server notes a rough location (country, region and city) from your connection and stores no IP address. Nothing is stored: name and
email live in the window and go when it closes. There is no network at launch, in the background or in
tests. The real sender exists only for an ordinary launch (no arguments, or `--background`); every
validation, render and diagnostic launch gets `OfflineFeedbackTransport`, and `--release-validate`
checks that.

## Checks

- `swift test --filter ProductFeedbackTests`: the request, the body's exact keys, the local checks
  (the server's own sentences), the reply mapping, the 15 s limit and cancellation, all through a
  fake transport.
- `MenuSprite --feedback-render <dir>`: every state of the window, the hub card, and the Tools tab's
  first screen, light and dark, off-screen. Nothing is shown or sent.

Not yet exercised on screen: typing, the shortcuts, activation from the hub, and a real send.
