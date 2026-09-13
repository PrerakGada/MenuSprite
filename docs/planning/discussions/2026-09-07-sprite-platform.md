# Original voice-typed product clarification

7 September 2026 · User-provided text, preserved verbatim below.
Speech-to-text spellings are retained. The product continues to be called
MenuSprite; the referenced repository is vorssaint/vorssaint-utils.

> https://github.com/vorssaint/vorssaint-utils
> This is one of the candidates that I was planning to use and I'm already using, but I want to replace it. There are many more small things that I'm using, and we have to change all of them.
>
> The reason that I want to make menus bright is that if we use any of these existing open-source products or many menu bar apps and tools, there are hundreds of them available. The issue is that they all come with their own flavor and appearance. There is very little customization that we can do, and I want to make something that is completely customizable. People should be able to design their own sprites. A sprite is any menu bar item. What happens on that sprite? What happens when you click that sprite? All of the things.
>
> We need to keep an option: Add/Create Custom Sprites. Sprites can also be installed. They can be installed with a version of the script that runs in the background that would maybe check the Claude usage, Codex usage. It would run some commands in the background to get more data about some specific app. It can be a Docker monitor. It can be anything, anything wildly.
>
> Basically, you want to create a playground where people can bring their own creativity, bring their own ad ideas, and then put all their sprites into this MenuSprite app. People can directly go on the marketplace and download anybody's things. They can like other sprites, and we will have friends and everything. Basically, it becomes an open ground for everybody to get their own ideas.
>
> Before we dive in very deep, there is one thing that I'm very confused about: this app Varsant that I just mentioned in the GitHub link above has a lot of other tools also, which are not just menu bar related. There are things like desktop switching, app switching, some monitoring things, and home view management. You can have all the homebrew installed and everything easily managed. There are also other third-party tools and different-use-case things that you can install.
>
> I was expecting this MenuSprite to have all of those things. It will have all the system-related things, shortcut-related things, and tools and helper things. They all will be kind of sprites only, but I don't know how we can fit them into the MenuSprite. I think MenuSprite became too much of a menu bar thing only and was restricted to that, not as a powerful thing that can have many more things added. What do you think about that?
>
> Of course, keep saving everything. I'm just raw voice typing everything that comes into my head.

Interpretation and recommendations are kept separately in
[the sprite platform direction](../sprite-platform.md). Broad utility support,
customization, installable sprites, marketplace, likes, and friends are user
intent. The exact surface/extension model remains a proposal. The follow-up below
settles the identity icon and menu bar visibility distinction.

## Follow-up: identity icon and menu bar visibility

User-provided text, preserved verbatim:

> Yeah, a sprite will have an icon, but it does not need to be shown in the menu bar. It can be hidden from the menu bar as well, but every sprite needs to have some icon because we have the name "sprite". Also, anything that any person makes should have an identifier icon or a mini logo, right? But it can be hidden.

Recorded as D-17 and R-17: every sprite has a visual identity icon; menu bar
visibility is optional and distinct from enabled/disabled behavior. Broader
window/overlay details remain under discussion.

## Follow-up: custom expanded menu board

User-provided text, preserved verbatim:

> Also whether the sprite same has a custom expanded menu board which opens on clicking that icon with custom UI and data rendered inside them.

Recorded in D-02 and R-18: a sprite may have its own optional custom expanded menu
board, opened on icon click, with custom UI and rendered data. Exact control
palette, layout constraints and native presentation remain design details.

## Follow-up: feasibility

User-provided text, preserved verbatim:

> DO you think everything we are talking about is actually possible?

The engineering assessment is saved in [feasibility.md](../feasibility.md): the
core platform is feasible in principle; universal system access, automatic visual
editability of arbitrary code, and negligible resource use for unrestricted
extensions cannot be promised. Existing APIs and source examples provide evidence
for building blocks; native proof and measured budgets still await development
authorization. This assessment is not a new user decision or scope reduction.

## Follow-up: data from existing menu bar items

User-provided text, preserved verbatim:

> But will we able to read the data displayed in other Menu Bar Items and show them in sprites created by us? Like maybe injecting a script that would monitor whats going on the target app's menubar item and have it cloned in our custom sprites with custom UI?

Saved as candidate D-21 / DATA-15 for app-specific validation in V-10. The proposed
approach is an external reader through available APIs or Accessibility; capture
and OCR are a less reliable fallback. Literal process injection is a different
mechanism and is not a universal capability. Mirroring may preserve a dependency
on the original app and its UI state. Detailed evidence and limitations are in
[feasibility.md](../feasibility.md); no native inspection or implementation ran.

## Follow-up: park external-app mirroring

User-provided text, preserved verbatim:

> Ok, I think we are going too deep in a direction that's not very important

Interpretation in context: pause further investigation/design of reading or
cloning other apps' menu bar data. D-21 / DATA-15 / V-10 are retained as low-priority
deferred ideas, not core prerequisites. Continue the broader product discussion
around creating, installing and customizing sprites, including their expanded
menu boards. This does not cancel the overall planning task or authorize development.
