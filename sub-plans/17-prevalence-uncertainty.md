# Sub-plan 17 — Show the uncertainty on prevalence and density

Roadmap position: **S2** on the stakeholder track (`sub-plans/model-accuracy-roadmap.md`, "Stakeholder
track").

## Why

The report shows bleaching prevalence as a bare percentage. Since sub-plan 10 it's computed over
*classified* colonies only, and that can be a small number. "40% bleached" from 5 classified colonies and
from 120 are very different findings, but they look the same today.
- **The panel** will ask how certain the figure is.
- **An LGU reader** may act on a number that is mostly chance.

Showing the interval is cheap, standard, and makes the app's claims honest.

## Decisions
1. **Prevalence:** a 95% **Wilson score interval** on (bleached, classified). Wilson rather than the normal
   approximation, because it behaves at small n and at 0% or 100% (it never gives a negative lower bound).
2. **Density:** a 95% interval on the colony **count**, using the exact Poisson (Garwood) interval, divided
   by the belt area (tape × belt width). Density's uncertainty from sampling one belt is real, though smaller
   in practice than prevalence's.
3. **Say what the interval covers.** It's *sampling* uncertainty only. It doesn't include detector misses,
   double counts or classifier errors; Phase E's recount comparison (sub-plan 14) measures those. The
   technical tab says so in one line. The executive tab doesn't add caveats beyond the plain-language
   framing below.
4. **Small-sample rule.** With **fewer than 10 classified colonies**, the executive tab shows "too few
   classified colonies to estimate bleaching reliably (n = 6)" instead of a percentage. The technical tab
   still shows the number with its interval. The threshold is a starting value, kept in one constant.

## Steps
1. `lib/services/transect_metrics.dart`: pure functions `wilsonInterval(successes, n, {z = 1.96})` and
   `poissonCountInterval(count, {alpha = 0.05})`. Garwood needs chi-square quantiles. Implement them from the
   gamma relationship (inverse regularized gamma by bisection is fine at these sizes), or use a small
   lookup for counts up to ~200 with the normal approximation above that. Pick the simplest that passes the
   tests, and document the choice.
2. `TransectReport`: `prevalenceInterval`, `densityInterval`, `prevalenceReliable` (n ≥ threshold).
3. **Executive tab:**
   - "About 18% of classified colonies were bleached (likely between 9% and 31%)"
   - or the too-few message
   - density as "≈ 0.42 colonies/m² (0.31–0.56)"
4. **Technical tab:** the exact interval and n, plus the one-line "sampling uncertainty only" note.
5. **Export:** the interval bounds in sub-plan 12's session CSV. Until 12 lands, put them in the
   share-sheet text.

## Tests
- Wilson against published reference values, for example 0/10, 5/10, 10/10 and 18/100 with known 95%
  bounds. Check it never goes outside [0, 1].
- Poisson against reference bounds for count 0, 1, 10 and 100.
- Report and widget tests:
  - n below the threshold shows the too-few message on the executive tab and the number on the technical
    tab
  - n at or above it shows the interval text

## Done when
- Every prevalence and density figure in the app carries its interval or the too-few message, and the
  technical tab states what the interval does and doesn't cover.
- The thesis can quote the same intervals from the export.
