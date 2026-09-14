# Sub-plan 4 — Storage + transect metrics

Dev Plan Track 3, §8-10. Needs sub-plan 3's tracked, health-labeled colonies to exist first.

## Steps
1. **SQLite storage** — one row per tracked colony: track ID, species + confidence, health label +
   confidence history, mask-derived size. Standard mobile persistence, no research basis needed.
2. **Model integration** — confirm the stored schema actually round-trips everything sub-plan 3
   produces before building analysis on top of it.
3. **Post-transect analysis** — density, size-frequency, bleaching prevalence. Structure mirrors
   established belt-transect reef survey methodology (English/Wilkinson/Baker's survey manual, NOAA
   NCRMP's belt-transect protocol, AIMS's marked-tape method) — this part *is* literature-grounded,
   unlike most of the rest of Track 3; cite it as such in writeups, not as an engineering decision.

## Done when
- A completed transect session produces density/size-frequency/bleaching-prevalence numbers computed
  from SQLite-stored tracked colonies, using the physical marked transect tape as the density
  denominator (per the AIMS-precedented decision) — not an estimated or GPS-derived distance.
