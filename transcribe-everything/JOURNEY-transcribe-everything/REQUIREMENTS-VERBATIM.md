# Minh's requirements — verbatim

Every message below is Minh's own words, copied exactly from the conversation transcripts, in order.
The plan must satisfy all of them; later messages refine earlier ones (S9–S10 clarify S3: the grip moves
the overlay; text is highlight-and-copy only, no drag-out).

## Earlier agent session (before the fork)

### P1

see ~/code/minh-qol-utilities/wtalk. similar to this and this UI, i want to build a local transcriber model with VAD on my computer that can start up, label speaker 1, 2, etc. have configurable settings on the fly, a very small UI footprint that just shows the text on screen, save it to some rolling buffer offline so i can have other tools use it. etc.

i want this to be able to be configured to listen to only one audio stream from one app at a time, or the microphone (considered abstractly to be its own app), and be able to do streaming transcription so the current parakeet might not work but parakeet transcribe aint even that good so not sure what to do here. maybe like sending chunks until there's confidence or a limit reached

### P2

your task is to go help me research latest transcription models that can work live/semi live with batching / pipelines that basically perfect this/and can run locally and find me something good. and relatively tiny memory footprint

### P3

or maybe not tiny tiny. but should fit on my computer

### P4

Answers to your questions:

What speech should I optimize for: English dictation, multilingual speech (which languages), or meetings with multiple speakers?
English dictation

### P5

it seems to me like parakeet ultra is absolute best?  how is the accuracy of this compared to awen 3? it seems the arch is so damn fast it smashes pareto for latency and acc

### P6

well deep research are there stock pipelines for apple i can toss on my machine to just run parakeet ultra and do live at intervals where it has high confidence or something somewhat

### P7

what are the other two options exacylhy

### P8

goddamnit im not even here for dictation im here for general transcription from any app stream i fuckign told you

### P9

can i just build my own, ik it violates but at the same time i have the chance to make it minimal and controllable. can we first make a new folder in code called transcribe-everything

### P10

in qol-utilities

### P11

can you inspect wtalk and can we make something fo similar structure to that? near identical? a setup script that downloads and stuff

### P12

and install that does stuff and stuff -- go read it

## This session

### S1

Just forked and switched to Claude. How do you think we can build this as fast as possible? Any way to avoid any sudo stuff? I don't need this protected by demonlock. Guess the only thing is the permissions.

The ideal UI is i boot up the app, and it goes to menu bar. On launch, or on click on menu icon + start transcriptions button, it starts up the engine. 

There is a small minimal UI that is literally see-through like you're seeing text captions on TV, no background. 

The icon shows yellow if engine is starting up.
The icon shows green if it's ready and processing. 

The start engine flow also checks and requests all permissions idempotently

At startup, and every 5s, the app also runs a catalog of all the windows that are present.

It live generates a list in Menu icon when you hover over a button Attach to Apps. It's a list of window names. Click on, then it check marks it 

Another option in menu is delete old transcriptions, which just nukes a dump of transcriptions created in same file on every startup keyed by startup time or something else idk.

Find a good idiomatic format for everything

And the way this should display is like transcription for past 20 sec or full sentence

UI looks like this, just streaming from the offline dump or something. Single source of truth
[First 5 characters of window] [Speaker 1] blah blah blah...
[First 5 characters of window] [Speaker 2] blah blah blah...
[First 5 characters of window 2] blah blah blah...

Only display speaker if multiple in same window

And just add lines like that. 

As for how to implement parakeet ultra, I want to make sure we are running on MLX and fast as possible. I'm not sure what the optimal transcription methodology is, but it's like detect silence and send chunks? Or constantly transcribe, and update when confident or constantly transcribe and occasionally pre-empt?

But then I want to do speaker recognition too

I think we can go on the assumption speakers will NOT be overlapping so I don't need models that are capable of handling that edge case but there's also this aspect of per-lifecycle fingerprinting what speakers exist and shit?

Let's think deep.

### S2

is ultra even better than parakeet and does core ml run even fasteR? would it be good to upgrade wtalk, or does parakeet earn its keep

### S3

oh anothe rthing: live transcript should be fully copy paste-from-able and drag-drop-able. i think two small buttons 

[6-dot grid to drag] ^ <- second button, bracket up, expand
the expand one shows the last minute of speech to copy paste from. the 6-dot grid drag/drops anywhere. and BELOW these is the lines. so

6 ^
[Zoom] xyz xyz xyz
[Chrome] xyz xyz xyz

etc.

Also if attaching only to one window, no need to display the [].

Also, any way to have the input stream as its own stream?

### S4

Okay tmrw I'll have sudo. Set up whatever u need to do u have the .app that has the perms I say hello then you run smth and it requests and u can go on your own completely after

### S5

can you have no fucking accessibility thing then if you dont need it?

### S6

in menu i also want ability to set an int within a range for font size. this is massive lol. wait can you pause asap when all your stuff in flight is at a point of conclusion then talk to me

### S7

to get to a fantastic strata-map by the time i wake up, what goal should i set fo ryou irreproachable? also i think a hide option in the menu would be nice or an eye icon in the small bar above the text?

### S8

no need for the morning brief, also your agent tools are back, also can you extract the first 100 user - asssistant or something convo in this convo or the firs tmsg where i was talking about all i wanted and give that to the agent to review against + all of the stuff i later mentioned like font size whatever

### S9

moves overlay around the screen... what the fuck

### S10

i never asked for the drag out feature. i just wanted to like highlight and copy it.... ??

### S11

make sure this repo is 100% decoupled from rac

### S12

eye hides the overlay but the three buttons there? eye is then crossed?
