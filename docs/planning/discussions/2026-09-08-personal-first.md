# Return to the first personal build

8 September 2026 · User-provided text, preserved verbatim:

> Yeah, I think we overengineered a lot of discussion. We should be at a point where we can start implementing at least all the important things that I want and just discuss that. Later, we can think about the sprites marketplace and all of the other things, and it can be added anytime. First of all, it should at least support all of the things that I want at a very, very low memory footprint, so that at least I can start using it.

Recorded direction: focus discussion on the important personal workflows and a
very low memory footprint; defer marketplace/social/platform expansion. Preserve
sprite identity, visual customization, optional menu bar visibility, optional
custom expanded menu boards, and broader system tools where needed. The daily
utility checklist is still missing; named examples are not automatically a
confirmed first-release scope.

[First personal build](../../first-personal-build.md) is the current brief. The
older whole-platform architecture is reference, not a prerequisite. This turn
updated planning only; no app scaffold, implementation or experiments ran.

## Actual utilities and desired replacements

User-provided text, preserved verbatim:

> In my menu bar right now, I have:
> - the system analytics monitoring, basically the RAM, CPU, and power usage
> - the network download/upload speeds going on
> - the Mac fan control app with that menu bar with the speed of the fans and the temperature
> - Aldente Pro, which is a graphical, very nice UI of my battery and controls how much percentage it should have and everything
> I have a couple of third-party other apps, but Vorssaint is mostly the three numbers. There is an app called Scalar, which is downloaded from the App Store and shows the upload/download speed. These ones are the things that we can replace with very easy work.
>
> But other than that, there will also be many things that I would like. I also use CleanShot and Paste, which are two very good apps that come under the Set app subscription, which I would like to build on this MenuSprite and work on MenuSprite here.

Recorded in D-01/D-23 and the current personal-build checklist. This answers the
previous missing-inventory question. "Scalar" is retained as the reported name;
no App Store identity has been verified. Exact power metric, fan control use,
additional AlDente controls and daily CleanShot/Paste operations remain unspecified.
No actual source-app settings, clipboard content or captures were inspected.

Assessment: CPU/RAM/network readings are a reasonable first implementation path.
Sensor/power readings need target-hardware validation; active charge/fan control
is separate work. CleanShot/Paste are real replacement goals, with personal scope
to define rather than presumed full product parity. No capability is dropped by
starting with the monitoring path.

Primary product references checked on 8 September:

- [Macs Fan Control](https://crystalidea.com/macs-fan-control): distinguishes monitoring from manual/sensor-based fan control and describes returning control to Auto on quit.
- [AlDente](https://apphousekitchen.com/aldente-overview/): charge limiting is distinct from graphical monitoring; additional modes exist, but Prerak's use of them is not established.
- [CleanShot](https://cleanshot.com/): capture, editing, recording and cloud sharing cover different workflows. Do not infer that Prerak uses all of them.
- [Paste](https://pasteapp.io/): history/search, pinned content and device sync are distinct capabilities. Only the app's use is confirmed so far.

Questions sent: which CleanShot/Paste features are used regularly; whether fan
speed is only monitored or changed; and which AlDente controls are used beyond
the charge limit. Answers pending when this record was written.

## Next step: a transparent permissions page

User-provided text, preserved verbatim:

> We need to go gradually, not directly start implementing MVPs. Now, we first of all need to have all the permissions that an application can take in macOS listed on a single page very easily, with each one shown as granted or not granted. We should have full control over every single permission, the way Wallet also has, so that it's very transparent and easy for me also to manage all the permissions that have been granted, similar to how Vorssaint is in that place.

Recorded as D-24 / APP-04. [Permissions & Access](../../permissions-page.md) is
the current step; the monitoring-first recommendation is postponed until after
this foundation. Interpret the requested overview as MenuSprite's own access and
its owned helpers, not an editor for all other applications. The named "Wallet"
reference is not identified; Vorssaint's actual permission guide/service was read.

The page must preserve the user's transparency/control goal with honest platform
limits: request supported access, open System Settings for OS-managed changes,
show genuine scoped states, and show Check in System Settings when the grant is
not queryable. macOS does not offer a universal query/grant/revoke API for every
permission. The spec includes the broad category catalog, scoped targets, and
other approval types on one page. No app permissions, settings or helper services
were changed. Planning documentation only; no native scaffold or MVP was built.

## Readiness to begin development

User-provided text, preserved verbatim:

> Yup, I think most of the stuff is planned. Is there anything else we should discuss before moving for Development?

Assessment: enough product planning exists for the first native app plus the
Permissions & Access page. Resolve toolchain, consistent app/signing identity,
native adapters and measured footprint during setup. Do not require the remaining
fan/battery/CleanShot/Paste or marketplace decisions before this step. Later
feature discussions occur when those features are reached. This question was a
readiness review; no native implementation or permission changes ran this turn.
