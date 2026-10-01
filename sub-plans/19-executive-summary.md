# Sub-plan 19 — Executive summary: what the LGU reads first

Roadmap position: **S4** on the stakeholder track (`sub-plans/model-accuracy-roadmap.md`, "Stakeholder
track"). It uses sub-plan 17's intervals and sub-plan 18's photos. **Step 0 is a decision** that has to be
made before the wording is final.

## Why

The Spec leaves this open. Phase D: "**[OPEN]** Exact content of the executive-summary tab not yet
designed." Sub-plan 06 restyled the tab without designing its content: a donut, two bars, a prevalence
sentence and density (`summary_screen.dart` `_ExecutiveTab`). For the LGU and the MPA managers, this tab
*is* the product, and today it doesn't answer their real questions:
- How is this reef doing?
- Is that worse than last time?
- Should we do anything?

## Step 0 — decisions to make first (people)
1. **Audience.** The Municipal Environment and Natural Resources Office, the MPA management board
   (Gilutongan, Alegria), or both? This decides the vocabulary and whether management actions are mentioned
   at all. Ask the adviser or the LGU contact.
2. **A cited bleaching-severity scale.** The tab may describe prevalence as "low / moderate / severe" **only
   with a cited source**. A candidate to check is the bleaching-prevalence categories used in large-scale
   bleaching surveys, such as the aerial-survey score bands in Hughes et al. (2017, *Nature*). **Verify the
   exact category boundaries in the paper before using them**, and record the citation in the Spec. If no
   suitable source is settled, the tab shows the number and its interval with **no** severity word. That's
   less friendly, but not invented.

## Content (top to bottom)
1. **One status sentence**, plain language, built from the data. For example: "34 coral colonies were
   surveyed along a 50 m transect at Gilutongan on 5 Oct. About 18% of those the app could assess were
   bleached (likely 9–31%)." Add the cited severity word only if step 0 settled a scale. Use sub-plan 17's
   too-few wording when the classified count is small.
2. **Compared with the last survey of this site**, if one exists: "Up from 9% on 12 Sep (same site)". Same
   site means the same normalized site name (trimmed, case-insensitive) for now. Proper site identity (a
   site list plus GPS, sub-plan 12) is future work. **Only say "up" or "down" when the two intervals don't
   overlap.** Otherwise say "similar to the last survey (9% then, 18% now; the difference is within the
   uncertainty)", so an LGU never reacts to noise.
3. **Photos of the bleached colonies** (sub-plan 18's strip).
4. **Key figures:** colonies surveyed, the healthy/bleached/uncertain breakdown (the existing donut and bars,
   which divide by classified colonies since sub-plan 10), and density with its interval.
5. **What this survey can't tell you** (two lines, fixed text): one transect is a sample, not the whole
   reef; and the app's labels are being validated against diver recounts (Phase E). Drop or shorten it once
   recount results exist.
6. Survey details in small text: date, site, observer, tape length, and the entry position once sub-plan 12
   lands.

**No track IDs, confidences or size-frequency here.** That's the technical tab (sub-plan 06's audience
split). Management recommendations stay out unless step 0's audience answer asks for them, and then only
cited ones.

## Steps
1. `lib/services/executive_summary.dart`: a pure builder from `TransectReport` plus the previous session's
   report to the content above (status sentence, comparison wording, flags). All wording decisions live here
   so they're unit-tested.
2. `TransectDatabase.previousSessionForSite(siteName, before: startedAt)`, with a test.
3. Rebuild `_ExecutiveTab` from the builder's output: sections 1–6.
4. Spec: close the Phase D `[OPEN]` with a pointer to this sub-plan, and record the severity-scale citation
   (or "none used").
5. Add a `docs/` explainer covering the comparison rule and the no-invented-thresholds rule.

## Tests
- Builder:
  - status sentence for normal, small-n, zero-colony and no-classified cases
  - comparison "up" only when the intervals separate, "similar" otherwise
  - no comparison with no previous survey, or a different site
  - the severity word only when a scale is configured
- DB: the previous-session lookup by normalized site name and date.
- Widget test: the tab renders the builder's sections in order, with and without a previous survey.

## Done when
- The tab answers "how is it, compared with last time, and how sure are we" in its first two lines, for a
  real survey.
- The Spec's executive-summary open item is closed, with the audience and the severity-scale source (or
  its deliberate absence) recorded.
