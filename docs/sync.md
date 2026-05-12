# How sync works

This is a plain-language guide to the iOS reader's sync behavior, written for the person doing the reading rather than the person doing the engineering. If you want the technical details, the code is where they live; this doc covers what you actually see.

## What gets synced

Your reading position. That's it. One position per book per account.

When you read a book on the iOS reader, your position is saved locally as soon as it changes (every page turn, every scrub). Every now and then iOS sends that position to your library server so other devices on the same account can pick it up.

The reader stores the position both as a chapter (which file in the EPUB you're on) and as a fraction-into-the-chapter (where in that chapter you are). Both pieces ride along when iOS sends or receives sync data.

## When iOS sends your position to the server

Not on every page turn. Three triggers:

- **You background the app.** iOS pushes the most recent position.
- **You close the book.** Same.
- **You bring the app back to the foreground.** If there's anything still pending (e.g. the previous push failed), it retries.

Page turns and scrubs only update the *local* position, never the server. This is intentional — sending on every page turn would chew up battery and bandwidth for no real benefit.

## When iOS asks "Continue from another device?"

The reader checks the server every time you open a book. If the server has a newer position than what's stored locally, and that position differs meaningfully from where you'd land here, you'll see an alert.

The exact rule:

| server's state | what happens |
|---|---|
| nothing on server | open at local position, no prompt |
| server is ours (we wrote it) | open at local position, no prompt |
| server is older than local | open at local position, no prompt |
| server is newer **and** in a different chapter | prompt |
| server is newer, same chapter, but > 1% different progress | prompt |
| server is newer, same chapter, ≤ 1% different progress | silently jump to server's position |

If the prompt fires, you'll see something like **"Another device is in 'Chapter 12' — switch?"** with **Continue** and **Stay here** buttons.

- **Continue** loads the server's position. The reader navigates there.
- **Stay here** ignores the server's position. You stay where iOS already had you, and your next page turn (or close-and-reopen) will overwrite the server with your iOS position.

The reader opens at the local position instantly, regardless. The server check happens in the background — the prompt appears a moment later if needed. If you start reading before the prompt arrives, it's suppressed (we won't yank you out of a paragraph mid-sentence).

## Cross-device handoff — the typical path

You're reading on a Kobo, swap to iOS:

1. On the Kobo: close the book and let it sync (Settings → Sync now, or just turn the device off; it syncs on idle).
2. On iOS: open the book. The reader appears at wherever it last had you on iOS. A moment later, the **"Another device is in '...'"** alert appears. Tap **Continue**.
3. You're now reading on iOS at the Kobo's position. From here, iOS owns the position. Next time you sync, the Kobo will pick up where you stopped on iOS.

You're reading on iOS, swap to a Kobo:

1. On iOS: close the book, or background the app. iOS pushes your position immediately.
2. On the Kobo: trigger a sync (Settings → Sync now). When you open the book, it lands at iOS's position.

## Known quirks

**Kobo's whole-book percentage can look off.** The Kobo device and iOS compute "you've read 35% of the book" differently. After a handoff you might see iOS say 50% and the Kobo say 35% even though you're on the same paragraph. The *chapter* is correct; the *percentage* is just an approximation that doesn't quite match across devices. This is a Kobo firmware quirk — out of our control.

**Span landing.** For most KEPUBs, iOS asks Readium for the actual paragraph you're currently looking at and pushes that to the server, so the Kobo device lands on the same paragraph. For non-KEPUB books (plain EPUBs without Kobo-specific markup), or unusual cases where the visible content isn't a tagged paragraph, iOS falls back to a linear-interpolation estimate that can be a paragraph or two off — swipe one page and you'll be at the right place.

**The prompt re-fires if you declined.** Tapping "Stay here" doesn't make iOS forget the server's position. If you close the book and reopen it without making any changes, you'll see the same prompt again (because the server is still ahead). The only way to silence it is to read forward past the server's position, or accept the server's position with Continue.

**Tiny advances jump silently.** If the server is less than 1% ahead of where you are within the same chapter (e.g. the other device read one more page), the reader silently jumps to the server's position. No prompt, no animation — you just open at the slightly-further spot.

## Troubleshooting

**The Kobo doesn't show iOS's position.**

- Did the iOS reader actually push? Background or close the iOS reader. The push happens then, not on every page turn.
- Did the Kobo actually sync from the server? Trigger a sync on the device (Settings → Sync now).
- Is the book a KEPUB or a plain EPUB? Plain EPUBs only sync chapter-level — the device opens at the chapter start, not the exact iOS position. KEPUBs round-trip the precise span. Check the file format in your library.

**iOS opens at the wrong position.**

- Were you the last writer? If you read on iOS, switched to the Kobo, read for a bit, then came back to iOS — iOS will only prompt if the server has a newer write than what iOS last had locally. If you read just a tiny bit on the other device, the prompt might not fire.
- Did you tap "Stay here" by mistake? Close and reopen the book — the prompt should fire again, since the server is still ahead.

**iOS keeps prompting even when I want to stay.**

That's the design: as long as the server's position differs from where you are, iOS will ask. The simplest way to silence it is to read forward past the server's position. Once your local position is ahead of (or equal to) the server's, no prompt.

**I see "Continue from another device?" with no chapter name.**

iOS knows there's a peer write but couldn't resolve the chapter title from the book's table of contents. The Continue button still works — it just doesn't have a friendly chapter name to display. Usually means the TOC is unusual; the EPUB might be malformed.
