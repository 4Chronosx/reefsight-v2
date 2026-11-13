# Aligning ReefSight with DENR-BMB Technical Bulletin 2019-04

> Copy of `docs/denr-tb-2019-04-alignment.md` from the ReefSight project folder, kept here so the GitHub issues can link to it. Paths like `docs/…`, `sub-plans/…` and `machine-learning-pipeline/…` refer to that project folder, not this repo. The diagrams and database schema are in [reefsight-v2-blueprint.md](reefsight-v2-blueprint.md).

After the CCEF meeting (November 2026), CCEF asked that ReefSight follow **DENR-BMB Technical Bulletin
No. 2019-04** (*Technical Guide on Biodiversity Assessment and Monitoring System [BAMS] for Coastal and
Marine Ecosystems*), so that its surveys are standardized with national reef monitoring. They also asked
that it measure more than bleaching. This document:

- summarizes what the bulletin requires for coral reefs
- assesses where ReefSight stands against each requirement
- lists what can be changed before the next dive (November 15, 2026) and what comes after

Sources: `paper/tb2019-04.pdf` and the bulletin it builds on, **TB 2017-05** (*Guidelines on the
Assessment of Coastal and Marine Ecosystems*, provided on November 13, 2026). Both were read in full.
TB 2017-05 holds the Photo Transect Method details (section 1b). Where the two differ, follow the newer
TB 2019-04. For example, TB 2017-05 says two 50 m transects per station and TB 2019-04 says three to five.

## 1. What TB 2019-04 requires for coral reefs (Annex 1, Section 1)

| Requirement | Bulletin text (paraphrased) |
|---|---|
| **Core method** | **Photo Transect Method (PTM)** for percent cover, species composition and abundance |
| **Station** | 75 m × 25 m (1,875 m²) monitoring station on the **upper reef slope**, at about 5 m depth, facing the NE or SW monsoon, with homogeneous coral (not patches among sand or rubble) |
| **Transects** | 3–5 **randomly placed** (not haphazard) **50 m transects** per station, each on a **uniform depth contour**. Five are recommended for monitoring. The deepest is no more than **6 m** below mean sea level |
| **Randomization** | Random distance along the 75 m axis and random swim-out distance (0–25 m) perpendicular to it (Fig. 3) |
| **Positioning** | GPS coordinates of the station, with a concrete block marking the deeper edge, so the station can be found again |
| **Metric 1: hard coral cover** | % HCC, reported on the new scale (Licuanan et al. 2017): **A >44%, B >33–44%, C >22–33%, D 0–22%** |
| **Metric 2: generic diversity** | Number of **Taxonomic Amalgamation Units (TAUs)**, a list of about 60 genus and growth-form units (Table 3). Scale (Licuanan et al. 2019): **A >26, B >22–26, C >18–22, D 0–18 TAUs** |
| **If no TAU expertise** | Use the TB 2017-05 **life-forms**, but still record **Porites branching, encrusting and massive (PORB, PORE, PORM)**, the **Acropora** life-forms and **Heliopora**, which indicate disturbance history and resilience |
| **Associated fish** | **Fish Visual Census** on the same transects |
| **Cryptobiota** | ARMS units at the monitoring stations (optional) |
| **Frequency** | Monitoring at least **once a year**. Reassessment every 3 years. **Assess immediately after catastrophic events, including high sea temperatures that may cause bleaching** |
| **Design** | Hierarchical where resources allow: 2 stations (100–200 m apart) per site, at least 3 sites (at least 1 km apart) per location |
| **Reporting** | Raw data kept by the protected area office. Processed data entered into the regional **CMEMP/Agos database**. Image libraries backed up with academic partners |

Two points from the bulletin help ReefSight's case:

- **Bleaching is a named trigger.** The bulletin requires immediate assessment after high sea temperatures that may cause bleaching. That is the moment a fast, phone-based survey is most useful.
- **New technology is invited.** Section 8 says the methods will be updated with "efficient and cost effective technologies that may be developed later on, and recognized by relevant institutions." The bulletin also already names an automated tool (ARRAS) for reconnaissance.

## 1b. Photo Transect Method details (TB 2017-05, coral reef section)

| Item | Specification |
|---|---|
| **Photos** | One photo **every 1 m** from the 0 m mark of a 50 m transect (about 50 frames per transect), from a still camera in an underwater housing |
| **Camera height** | **1.2 m from camera to substrate**, held constant with a stainless distance bar: a **tetrapod**, or a **monopod with a 1 m foot**. The tetrapod's base is a **1 m × 1 m inner frame** |
| **Lens** | Full wide angle |
| **Camera spec** | **At least 5 MP**, in an underwater housing, or a GoPro |
| **Scoring** | **CPCe** (Coral Point Count with Excel extensions). A **1 m × 1 m area** is defined in each photo and **10 random points** are overlaid. The benthos under each point is identified by life-form, and hard coral by genus |
| **% cover** | Points of a category ÷ total points per transect × 100. Tape, shadow, wand and blocks are excluded from the total |
| **Categories** | 28 benthic life-forms (English et al. 1997). Hard coral: Acropora branching, digitate, sub-massive and tabulate (ACB, ACD, ACS, ACT); non-Acropora branching, encrusting, foliose, massive and sub-massive (CB, CE, CF, CM, CS); Millepora (CME); Heliopora (CHL); mushroom (CMR). Others: dead coral (DC), dead coral with algae (DCA), soft coral (SC), sponge (SP), zoanthids (ZO), other animals (OT), algal assemblage (AA), coralline algae (CA), Halimeda (HA), macroalgae (MA), rubble (R), sand (S), silt (SI), unidentified (UNID) |
| **Bleaching** | The sample CPCe sheet has a **"Bleached coral (BLEC)"** subcategory under hard coral, so bleaching can be reported as **% cover of bleached coral** inside the standard method |
| **Output format** | One CPCe sheet with a column per transect: number of frames, total points, points excluding tape, shadow and wand, % cover per major category (HC, AA, abiotic, MA, HA, other biota, tape/shadow), and per subcategory. Then the **mean, SD and SE across transects** |
| **Status scale** | Excellent >44%, Good 34–44%, Fair 22–33%, Poor 0–22% live coral cover. This is the same scale as TB 2019-04's categories A–D |
| **Extras** | Close-up photos of colonies may be taken to help identification. Station GPS, and concrete blocks at monitoring sites. Monitoring once or twice a year |
| **Fish (FVC)** | Same tapes, starting about **20 min after laying them**. Fish within **5 m left, right and above** the line are identified, counted and sized to the nearest cm, by 5 m segment. Biomass is W = aL^b |

## 2. Where ReefSight stands

Checked against the code on November 13, 2026:

- `screens/transect_setup_screen.dart` has fields for tape length (default 50 m), site and observer.
- `belt_width_meters` exists, and density is computed as colony count ÷ (tape length × belt width) in `services/transect_metrics.dart`.
- Colony size is in **pixels only** (`services/colony_size.dart`).
- Entry and exit GPS are surface fixes (`docs/entry-exit-gps-fixes.md`).
- Segmentation has a **single "coral" class** (`docs/class-agnostic-segmentation-vs-genus-naming.md`).

| TB 2019-04 parameter | ReefSight today | Status |
|---|---|---|
| % hard coral cover (HCC) | Not computed. The segmenter outputs coral masks per frame, but nothing turns them into a cover percentage | **Gap, but the raw material exists** |
| HCC category A–D | Not reported | Gap (easy once % HCC exists) |
| TAU / generic diversity | Not available. Genus-level segmentation was tried and failed across domains, which is why Stage B is class-agnostic | **Major gap** |
| Life-forms (ACB, CB, CM, CE, CF, …) and PORB/PORE/PORM, Acropora, Heliopora | Not available | **Major gap** |
| Other benthos (soft coral, dead coral, algae, sand, rubble) | Not separated: anything that isn't coral is background | Gap |
| Photo Transect Method frames | The app records handheld, oblique video, not one photo per meter from 1.2 m with a 1 m × 1 m frame. The video resolution isn't set in the Dart code (it's the plugin default), so frames may be under the 5 MP minimum (1080p is about 2 MP) | **Gap**. The iPhone 14's 12 MP still camera meets the spec |
| Real-world scale (cm², per m²) | Colony size is in pixels only | Gap. A 1 m × 1 m frame in every photo would provide the scale |
| Bleaching within the standard method | Per-colony bleached or healthy labels | Fits: CPCe's "Bleached coral (BLEC)" category allows reporting % bleached coral cover |
| 50 m transects | The setup field defaults to 50 m | **Meets** |
| 3–5 random replicates per 75 × 25 m station | No station or replicate fields. Each transect is a separate session | Gap |
| Upper reef slope, uniform depth contour, ≤6 m | Oct 4 transects were on the **reef flat** at about 5 m. No depth field | **Protocol gap** |
| Station GPS for relocation | Surface entry/exit fixes, but GPS failed inside the housing on Oct 4 | Partial |
| Fish Visual Census | Out of scope | Not planned |
| Annual monitoring, and rapid assessment after bleaching | Bleaching flags exist, but the classifier is weak locally (3 of 67) | Partial: this is the strongest fit, but it needs fine-tuning |
| Raw data archive and image library | CSV export, colony photos and session files | **Meets in spirit**. No CMEMP/Agos format yet |
| Colony counts, density, size-frequency | Supported (size in pixels) | **Beyond TB 2019-04**: the bulletin doesn't ask for these, though they are still useful |

**In short:** ReefSight currently measures things the bulletin doesn't require (colony counts and per-colony bleaching) and doesn't yet measure its two headline metrics, **% hard coral cover** and **generic diversity**. The good news is that % HCC is within reach, because the segmenter already finds coral pixels. Diversity is the hard part.

## 3. Before the November 15 dive (two days)

Two days is too short to retrain models or make risky database changes. The best use of this dive is to **collect data in the bulletin's format**, so that HCC and diversity can be built and validated afterwards against expert-scored data from the same transects.

### Field protocol (no code needed)

1. **Survey a bulletin-style station.** Pick an upper reef slope at about 5 m, no deeper than 6 m, with homogeneous coral. Mark out a 75 × 25 m station and lay **five 50 m transects at random positions** (use random numbers for the along-station distance and the 0–25 m swim-out, as in Fig. 3). Keep each tape on one depth contour. If five transects is too much for one dive, do three, the bulletin's minimum.
2. **Do a standard photo transect on each tape.** Build or borrow a **monopod (1.2 m pole with a 1 m foot) or a tetrapod with a 1 m × 1 m PVC base frame**. CCEF or UP may already have one. At every meter mark from 0 to 50 m, take **one still photo from 1.2 m, pointing straight down, at full wide angle**, with the frame in view. Use the iPhone's built-in Camera app (12 MP, above the 5 MP minimum). If that can't be done through the housing, use a GoPro or other underwater camera.
3. **Record ReefSight on the same tape, as a separate pass.** If possible, film from the same monopod, straight down at 1.2 m, pausing at each meter mark. That gives the app top-down, constant-height footage with a known 1 m × 1 m scale in view. That footage is closer to the top-down NOAA images the classifier was trained on, and to the scale the segmenter saw in training. Flag this pass as a different camera geometry from Oct 4, so the results aren't pooled. *(See `docs/coral-instance-scale-mismatch.md` before relying on detections at a new camera height.)*
3. **Never leave the tape line.** This fixes the afternoon overcount (+75.8% on Oct 4) and ties every frame to a distance along the tape, which density and cover both need.
4. **Get expert reference data for the same transects.** Ask a CCEF or UP marine biologist either to score the extracted photos afterwards with the standard PTM point method in CPCe or CoralNet, or to record life-forms and TAUs along the same tapes. At minimum, ask them to record **PORB/PORE/PORM, the Acropora life-forms and Heliopora**. This becomes the ground truth for ReefSight's future HCC, life-form and diversity outputs.
5. **Record station data on a slate**, since the app has no fields for it: station ID, transect number (1–5), depth at the start and end of each tape, reef zone, and the random numbers used.
6. **Take a GPS fix at the station's deeper edge** with a phone or GPS unit **outside the housing** (GPS failed inside it on Oct 4). Note whether a concrete block was placed.
7. **Repeat the Oct 4 recommendations:** start on a full battery, fill in survey metadata instead of leaving defaults, put the HOBO logger on the tape reel, and run the blind recount on the same videos.
8. **Keep collecting bleaching labels.** Ask the expert to rate bleaching on the same colonies, with a written definition agreed in advance, to work toward the κ ≥ 0.40 gate.

### Small app changes (only if they can be finished and tested on the device by November 14)

- **Lowest risk:** no schema change. Put station, transect and depth into the existing site field using a fixed pattern, for example `Alegria-S1-T3-5.2m`. That keeps them in the CSV with no database migration two days before a dive.
- **Optional, if time allows:** a **"meter mark" tap** that writes a timestamp to the session each time the diver passes a meter mark. That makes frame extraction exact. Skip it if it can't be tested on the device first, because a new feature that breaks underwater loses the dive.
- Confirm that the two known field bugs (recordings saved rotated 90°, metadata left at defaults) are fixed or worked around.
- **Don't change the models before this dive.** Keep the Oct 4 configuration so results are comparable.

## 4. After the dive: the path to TB 2019-04

In order of value and feasibility:

1. **% hard coral cover in the CPCe format (highest priority).** For each 1 m × 1 m photo, find the frame, place **10 random points** inside it, and label each point from the segmenter's mask. Report % cover per transect, the **mean, SD and SE across transects**, and **HCC category A–D**. Lay the output out like the CPCe sheet, so experts can compare it directly with their own scoring of the same photos. Mask area ÷ frame area is a useful second estimate.
   - **Starting model:** the CoralscapesV2 authors' released segmenter,
     `EPFL-ECEO/segformer-b5-finetuned-coralscapesv2-1024-1024` (84.6M parameters, 59.0 mIoU across 39
     classes; see `docs/coralscapesv2-dataset-review.md`). It labels every pixel as live, bleached or
     dead coral by genus, soft coral, algae, sand, rubble or transect tape, which maps directly onto
     the CPCe major categories, including bleached coral. Point scoring doesn't need separate colonies.
     It needs **no training**: run it **on a laptop** on the November 15 photo-transect stills and
     compare with the expert's CPCe scoring. It is **too large for live use on the phone**. A phone
     version would mean fine-tuning a smaller multi-class model on CoralscapesV2 and local data later.
     Caveats: Red Sea training data; 39 grouped classes, not the dataset's 95, with no soft-coral,
     encrusting, foliose, Porites or Heliopora class and bleached variants for only some forms (mapping
     in section 7); and CC BY-SA 4.0 share-alike terms.
   - **Caveat:** the segmenter's "coral" class isn't the bulletin's "hard coral". It may include soft coral and dead coral. It will need checking, and possibly retraining, to separate live hard coral.
2. **More benthic classes.** Retrain Stage B to separate live hard coral, soft coral, dead coral, algae, sand and rubble. CoralscapesV2, already used in training, has fine-grained labels that may support this.
3. **Life-forms first, then TAUs.** Automatic genus naming already failed across domains, so start with growth forms (branching, massive, encrusting, foliose, plate) and the bulletin's priority units (Porites ×3, Acropora, Heliopora). For full TAU diversity, use **expert review**: the app already saves a photo per colony, so a reviewer can tag each one with a TAU and the app counts the TAUs present. That gives the bulletin's diversity category without claiming the model can identify genera.
4. **Station and replicate structure.** Add station, transect number, depth and reef zone to the setup screen. Report per-station mean ± standard error of HCC across the 3–5 transects, since the bulletin uses that variability to choose monitoring stations.
5. **Reporting format.** Get the CMEMP/Agos database template from DENR or BMB, or through CCEF, and add an export that matches it. Keep the raw-data and image-library export.
6. **Bleaching as a rapid-assessment module.** Position it as the bulletin's "immediately after high sea temperature" assessment, alongside the annual monitoring. Fine-tune it with the expert-reviewed colonies.
7. **Out of scope for now:** Fish Visual Census and ARMS. If asked, the app could later add a simple fish tally, but that isn't a machine-learning task.

## 5. Questions to settle with CCEF

- Can a CCEF or UP expert score PTM points, or life-forms and TAUs, on the November 15 transects? Who, and how soon afterwards?
- Can they lend a monopod or tetrapod (1.2 m, 1 m × 1 m frame) for November 15? Do they score with CPCe, as TB 2017-05 says, or with CoralNet, and do they use the 10-point default?
- Can someone run a Fish Visual Census on the same tapes (starting about 20 min after laying them)? ReefSight doesn't cover fish.
- Can they share the CMEMP/Agos data template?
- Should ReefSight's first bulletin-aligned target be % HCC with categories, with diversity coming later through expert review?
- Would CCEF accept a validated virtual frame (section 6) in place of the physical tetrapod or monopod? What agreement with the physical frame would they need to see?

## 6. Proposed optional feature: frame mode (Physical or Virtual)

TB 2017-05's photo method needs a physical tetrapod or monopod to keep the camera 1.2 m above the bottom
and to mark a 1 m × 1 m scoring area. The proposal is a **virtual frame**: the app checks the camera's
angle and distance, draws the 1 m × 1 m square on the live preview, and takes (or allows) the photo only
when the shot is usable. It is **optional**. The diver chooses the mode for each session, and the
physical frame stays the default.

### The two modes

| | **Physical frame** (default; follows TB 2017-05) | **Virtual frame** (optional) |
|---|---|---|
| Distance and scoring area | Set by the tetrapod or monopod. The real 1 × 1 m frame is in the photo | Measured by the app. The 1 × 1 m square is drawn on screen and saved with the photo as its crop |
| Angle | Held by the pole | Live tilt from the phone's motion sensors, with a level indicator on screen |
| Capture | Diver triggers each photo | Diver triggers, or auto-capture when the angle, distance and steadiness checks all pass |
| Gear | Frame and pole | None extra (tape-as-ruler), or two parallel lasers on the housing |
| Standing | The standard method | **Experimental until validated** against the physical frame (TB 2019-04 Section 8 allows recognized new technology) |

### How the virtual frame measures

1. **Angle:** the phone's accelerometer and gyroscope give the camera's tilt from vertical. Capture is
   allowed only within a set tolerance (start at ±5°, then tune it on data). A tilted camera biases cover,
   because near coral looks larger than far coral, so this check is **strict**.
2. **Distance to the bottom:** the iPhone 14 has **no LiDAR**, and LiDAR works poorly underwater anyway.
   The barometer reads the air inside the housing, and AI depth estimates aren't in meters. So the
   distance comes from a known scale in the image:
   - **Paired lasers (preferred):** two parallel lasers (green carries better underwater) at a fixed
     spacing, for example 10 cm. The gap between the two dots in pixels, with the calibrated lens,
     gives the distance and the cm per pixel. This is a standard method in marine science.
   - **Tape as a ruler (no hardware):** the tape's known markings give the scale. It needs more
     detection work.
   - **ARKit (the technology behind Apple's Measure app), untested underwater:** even without LiDAR, it
     works out distances in meters from camera motion and the motion sensors. Risks: the housing's flat
     window magnifies the image about 1.33×, which may skew its scale or break tracking; it needs the
     camera to move; particles, low light and uneven reef make tracking harder; and an ARKit session
     takes over the camera, so it could only run during Virtual-mode photo capture, through native iOS
     code. **Test it first, with no code:** on the dive or in a pool, use the Measure app in the housing
     on the physical 1 × 1 m frame from about 1.2 m, several times. Consistently about 1 m means ARKit
     is usable. Consistently off by the same factor means a fixed calibration can correct it. Unstable
     or failing means use the lasers or the tape.
   - The distance check can be **loose** (start at 1.0–1.4 m). % cover is a ratio of points inside the
     square, so being a little off in distance changes which area is scored but doesn't bias the result
     up or down. Exact distance matters more for colony size and density.
3. **Steadiness:** the gyroscope confirms the phone is still, so the photo isn't blurred.
4. **The square:** from the distance, angle and an **underwater lens calibration**, the app works out
   which pixels cover 1 m × 1 m, draws them, and saves that crop with the photo for 10-point scoring.
   The housing's flat window narrows the view underwater. A rough estimate (to be measured) is that the
   main camera covers only about 1.1 × 0.85 m at 1.2 m, so the full square may need the ultra-wide lens.
   That lens distorts the image, so the calibration has to correct for it.

### Rules so the two modes don't get mixed up

- The mode is chosen on the setup screen and **stored with the session**, as the classifier settings are
  (`docs/classifier-settings-per-session.md`). It can't be changed mid-transect.
- Every exported photo and CSV row records the mode. For Virtual mode it also records the measured tilt,
  distance and check results.
- Reports **never pool** Physical and Virtual results. Virtual-mode results are labeled "experimental"
  until validation is done.
- Physical mode behaves exactly as today. The new code only runs when Virtual is chosen.

### Build order

1. **Level indicator (in both modes).** Tilt is shown on screen and saved with each photo. It is small
   and self-contained. Build it before November 15 **only if** it can be tested on the phone the day
   before; otherwise build it after the dive.
2. **Lens calibration underwater.** In a pool, photograph a 1 m × 1 m square at known distances with each
   lens, and measure the real field of view through the housing.
3. **Distance from lasers (or the tape).** Add dot detection and a distance and scale readout.
4. **Virtual square and auto-capture.** Draw the square, crop the saved photo, and capture automatically
   when all checks pass.
5. **Validation.** On the same tapes, compare Physical and Virtual mode on % hard coral cover per
   transect, both scored the same way. Agree the acceptable difference with CCEF **before** running it.

## 7. Proposed survey type: Preliminary (live video)

The bulletins' official numbers come only from **photo transects**: stills every 1 m from 1.2 m,
scored with 10 points in CPCe (section 1b). A **live video** survey isn't the standard method, but it is
useful as a **preliminary survey**. TB 2019-04 already allows a rapid automated tool for
"reconnaissance and mapping purposes" (it names ARRAS), and that's the role this mode fills.

### What it's for
- **Reconnaissance and station selection:** a quick swim to check whether a reef meets the bulletin's
  criteria (homogeneous coral, upper reef slope, ≤6 m) before setting up a 75 × 25 m station.
- **Rapid check after a heat event:** a same-day estimate of bleaching while the formal survey is
  organized. The bulletin requires assessment immediately after high sea temperatures.
- **Screening many spots quickly,** to decide where formal photo transects are worth doing.

### How it works
- The diver swims the tape, or a reconnaissance path, recording live video as ReefSight does now.
- The app takes frames at set intervals, places **10 random points** on each (as in CPCe), and labels
  them with the segmenter. That gives a **running cover estimate** during the dive.

### Output: the bulletin's categories, marked preliminary
The CoralscapesV2 classes are mapped onto the TB 2017-05 categories, so a preliminary report looks like
an official one and the two can be compared line by line:

| TB 2017-05 category | Coralscapes classes mapped to it |
|---|---|
| **Hard coral (HC)** | All live hard-coral taxa |
| ↳ **Bleached coral (BLEC)** | The "bleached" variant of each hard-coral taxon |
| **Dead coral (DC / DCA)** | The "dead" coral variants (and algae-covered dead coral, if labeled) |
| **Soft coral (SC)** | **Not available.** The model has no soft-coral class (see the gaps below) |
| **Algae (AA, CA, HA, MA)** | Algae classes |
| **Other biota (SP, ZO, OT)** | Sponges, clams and other invertebrates |
| **Abiotic (R, S, SI)** | Rubble, sand and other substrate |
| **Excluded: tape, shadow, other (TWB)** | Transect line and tools, fish, divers and other human-made objects, water and dark areas. Removed from the point total, as CPCe removes tape and shadow |

**Checked November 13, 2026 against the model's `config.json` on Hugging Face:** the released model
uses **39 classes** (ids 1–39, plus 0 "unlabeled"), **not** the dataset's 95 fine classes. They mix
growth forms and genera, with alive, bleached and dead variants. Draft mapping (to review with CCEF):

| TB 2017-05 | Model classes |
|---|---|
| ACT | table acropora alive |
| Acropora (form unspecified) | acropora alive |
| CB | branching alive, pocillopora alive, stylophora alive |
| CM | massive/meandering alive, meandering alive |
| CME | millepora |
| HC (form unclear) | other coral alive, turbinaria |
| BLEC | other coral / massive-meandering / branching / meandering **bleached** |
| DC | branching / massive-meandering / meandering / table acropora / other coral **dead** |
| DCA / AA | algae covered substrate |
| SP, OT | sponge, clam, sea cucumber, sea urchin, anemone, crown of thorn, seagrass |
| S, R, abiotic | sand, rubble, unknown hard substrate |
| Excluded (TWB) | transect line, transect tools, human, fish, trash, dark, background, unlabeled, dead clam |

**Gaps against the bulletin:**
- No soft-coral class. SC probably falls under "other coral", so it can't be reported separately.
- No encrusting or foliose classes (CE, CF).
- No bleached class for acropora, table acropora, pocillopora or stylophora, so bleaching in those is
  missed or misassigned.
- No Heliopora or Porites classes, which TB 2019-04 specifically asks to be recorded.

If these gaps prove important against expert CPCe scoring, the fix is to train a model on the
dataset's full 95-class labels (already on disk), which gives up the no-training advantage.

The report gives:
- **% cover per category for each transect,** then the **mean, SD and SE** across transects, in the
  CPCe sheet's layout.
- **% hard coral cover** with an **indicative** grade (Excellent/Good/Fair/Poor, A–D), labeled
  "indicative — preliminary video, not a TB 2019-04 assessment".
- **% bleached coral cover**, the main number for a rapid check after a heat event.
- **Number of frames and points used,** and how many points were excluded.
- **The cover estimate uses the CoralscapesV2 segmenter**
  (`EPFL-ECEO/segformer-b5-finetuned-coralscapesv2-1024-1024`), not the in-house YOLOv8n-seg. That
  gives the full categories (hard, soft, bleached and dead coral, algae, sand, rubble) instead of
  just coral or not coral. Coralscapes was filmed as diver video, so it suits this mode well.
  - **Sampled frames, not every frame.** At 84.6M parameters it can't run at the live loop's 6–7 fps.
    A cover estimate only needs about one frame every 1–2 s, so it runs on sampled frames in a
    background isolate. Speed on the iPhone 14 is **unmeasured**: convert it to Core ML, then
    benchmark at 1024 and at 512 input (512 is about 4× cheaper) before committing.
  - **If it's too slow live:** process the recorded video on the phone after surfacing (results on the
    boat), or on a laptop.
  - **No colony counting in this mode** (decided November 13, 2026). Preliminary surveys report
    bulletin-aligned cover only, so the in-house YOLOv8n-seg, the tracker and colony photos don't run.
    The SegFormer is the only model in this mode.
  - **Caveats:** the SegFormer is much heavier per frame than YOLO, so heat and battery need checking
    (a heat warning appeared on Oct 4).
    Shipping the weights in the app may carry share-alike terms (the dataset is treated as
    CC BY-SA 4.0), so confirm the model's own license. Red Sea training data means local validation
    is needed. Not feasible before November 15.

### How it's kept separate from the official numbers
- **Survey type** is chosen on the setup screen: **Photo transect** (standard) or **Preliminary
  (video)**. It's stored with the session and can't be changed afterwards.
- Every preliminary result is labeled **"Preliminary — not for official reporting (TB 2019-04
  reconnaissance only)"** on screen, in the report and in every export row.
- Preliminary results are **never pooled** with photo-transect results. Their grade is always shown as
  **indicative**. The export uses the CPCe sheet's **layout** so the two can be compared, but every
  file name and header is stamped **PRELIMINARY**. Preliminary results are never exported in the
  CMEMP/Agos submission format.

### Known biases (stated in the report)
- **Oblique angle:** coral near the camera takes up more of the frame than coral farther away, so cover
  can be skewed.
- **No fixed scale or area:** the distance to the bottom varies and there's no 1 × 1 m frame.
- **Frames overlap:** consecutive frames show the same coral, so they aren't independent samples. The
  estimate's uncertainty is wider than a simple count of frames suggests.
- The existing counting caveats apply too, for example drifting off the tape.

### Validation
On the same tapes, compare preliminary video cover with photo-transect cover, both scored the same way.
If they agree closely enough, the preliminary mode becomes a dependable screening tool. If they don't,
the comparison shows how far off it is and in which direction, and that goes in the report.

## 8. Proposed feature: stations (grouping transects)

The bulletins assess a **station**, not a single transect. TB 2019-04 calls for 3–5 random transects per
75 × 25 m station and uses the variation between them to choose monitoring stations. TB 2017-05's CPCe
sheet reports one column per transect, then the mean, SD and SE. So the app makes the station a record
of its own, for **both survey types**.

- **Station record:** ID, name, date, GPS of the deeper edge (surface fix), reef zone, depth range,
  **survey type and frame mode** (fixed for the whole station). Transects are numbered T1–T5, each with
  its depth and random placement numbers. Each existing session becomes a transect.
- **Summary:** % cover per category for each transect, then **mean, SD and SE** across transects
  (SE = SD ÷ √n). Each transect's percentage is averaged; points are **not** pooled, because the
  transect is the unit of replication. The hard coral grade and % bleached coral come from the
  **station mean**. Diversity (later) is the number of distinct genus groups across all transects
  (confirm with CCEF).
- **Export:** one sheet per station in the CPCe layout (T1…Tn columns, then mean, SD, SE).
- **Checks:** fewer than 3 transects is marked as below the TB 2019-04 minimum (with 1 transect there is
  no SD or SE). Mixing survey types or frame modes in one station is not allowed. Depth over 6 m or a
  tape not 50 m long is flagged. Preliminary stations get the same summary, stamped PRELIMINARY with
  an indicative grade.
- **Higher levels (later):** design the station record so it can belong to a site and a location
  (TB 2019-04: 2 stations per site; at least 3 sites, at least 1 km apart, per location). Only the
  station level is built now.
- **Timing:** this needs a database change (a stations table, with each transect linked to a
  station), so not before November 15. On that dive, record the station ID and transect number on the
  slate and in the site field, so the transects can be linked afterwards.

## 9. Proposed feature: importing photo-transect photos

Photo transects don't have to be shot in ReefSight. TB 2017-05 accepts any camera of at least 5 MP in a
housing, or a GoPro. Users can shoot with their own camera and **import the photos afterwards for
analysis**. Imported transects go through the same pipeline as in-app ones.

- **Where:** inside a station, on a transect, choose "Import photos" from the iOS Photos library or the
  Files app. Originals are copied into the app's storage; the source files are never changed.
- **Ordering:** photos are sorted by capture time (EXIF), with filename as a fallback, and assigned to
  meter marks 0, 1, 2… The user can reorder them, drop extra shots, and mark gaps (for example, "no
  photo at 23 m").
- **Defining the 1 × 1 m area:** as in CPCe, the user drags four corners onto the **physical frame** in
  each photo. The app can suggest them by copying the previous photo's corners, and later by
  detecting the frame automatically. Points are placed only inside that area.
- **Checks:**
  - photos under 5 MP are flagged
  - a count far from the expected 50 (or 51) per transect is flagged
  - **fisheye** images (for example, GoPro Wide or SuperView) are flagged; recommend **Linear** mode,
    which is also how Coralscapes was filmed, or apply a lens correction
  - imported photos without a visible frame can't be scored as an official photo transect
- **Recorded with each photo:** source (in-app or imported), camera make and model and capture time
  from EXIF, the corner positions, and the meter mark. All of this appears in the export, so imported
  and in-app results can be told apart and compared.
- **Analysis:** on the phone with the Core ML model (once benchmarked), or **later on a laptop** with
  the same model. Import works offline. Analysis can wait until the user starts it, for example after
  the dive.
- **Station rules:** a station can mix in-app and imported transects, since both are photo transects
  and the source is recorded. It can't mix in Preliminary (video) results.
- **Useful beyond ReefSight's own surveys:** CCEF, DENR or university teams could import their
  **archived** photo transects to get an automatic first pass, or to check ReefSight against
  surveys they've already scored by hand.

## 9b. Proposed feature: upload to Google Drive

A simple, manual upload of a survey's files to the user's own Google Drive. This is **not** the cloud
sync in `mobile/sub-plans/07-cloud-sync.md`: there is no backend, no ReefSight account and no syncing
between phones. It's a way to back up and share a finished survey.

The feature comes in two layers. The simple one is built first, and the in-app upload is built on top
of it.

**Layer 1, built first: Save to Drive through the iOS share sheet (no sign-in code).**
- On a station or transect, tap **Share / Save**. The app packages the selected files (summaries,
  images, video) in the same `<station code>_<date>/T1…` folder layout and opens the iOS share sheet.
  The user picks **Save to Files → Google Drive** (with the Google Drive app installed), or AirDrop,
  email or anything else.
- It needs no Google Cloud project, no OAuth and no Drive API code, so it's the quickest to ship. It
  reuses the existing CSV export.
- Limits: the app can't track what was already uploaded, can't resume a dropped upload, and depends
  on the Drive app, so very large videos are unreliable this way.

**Decided November 14, 2026:** only layer 1 is built for now. The share sheet must keep files organized
into the station and transect folder layout above. Layer 2 is **deferred**.

**Layer 2 (deferred): in-app Upload to Drive.**
- **How:** on a station or transect, tap **Upload to Drive**. The first time, the user signs in with
  Google (`google_sign_in`). The app asks only for the **`drive.file`** scope, so it can see only the
  files it creates, never the rest of the user's Drive.
- **Folder layout:** `ReefSight/<station code>_<date>/`, with the station summary at the top and one
  folder per transect (`T1/`, `T2/`…) holding its photos or sampled frames, its video and its
  per-transect files. Colony-count surveys use the same layout.
- **What's uploaded (the user picks):**
  - **Summaries:** the station summary and per-transect cover in the CPCe layout (CSV), and the
    existing session and colony CSVs. These are small and always selected.
  - **Images:** photo-transect stills (in-app or imported), sampled preliminary frames and colony
    photos.
  - **Videos:** off by default because they're large (roughly 0.6–1.2 GB per transect, unmeasured;
    see sub-plan 07). There's a "Wi-Fi only" option.
- **Reliable on poor signal:** large files use Drive's **resumable upload**, so a dropped connection
  continues where it stopped. Each file's status is stored (see the schema), so tapping Upload again
  sends only what's missing or changed, without duplicates.
- **Offline-first:** nothing uploads automatically. The app works fully without a network, and the
  upload is a step taken back on land.
- **Storage:** files count against the user's own Drive quota (15 GB on a free account). The app
  shows the total size before uploading.
- **Setup work:** a Google Cloud project with an iOS OAuth client ID and a consent screen. Until the
  app is verified by Google, only listed test users can sign in. That's fine for the team and CCEF
  testers.
- **Not before November 15.** Until then, copy files off the phone manually.

## 10. Decisions (November 13, 2026)

- **Where the Coralscapes analysis runs: both, on a laptop and on the phone.** Laptop analysis
  (a notebook using the same model and the same class mapping) starts right after the November 15
  dive. A **native Core ML bridge** for running the SegFormer on the phone is built alongside it.
  This **changes the locked architecture rule** in `mobile/CLAUDE.md` and the Specification (Phase C,
  "Live inference"), which allow only the `ultralytics_yolo` plugin. Update both documents when the
  bridge is built: the bridge is for the cover segmenter only, and YOLO models stay on the plugin. The
  bridge goes ahead only if the on-device speed test is acceptable. Each transect records where it
  was analyzed (`analyzed_on`: phone or laptop).
- **Colony-count mode is kept as a third survey type,** alongside Photo transect and Preliminary
  (video). It uses YOLOv8n-seg, BoT-SORT, the bleaching classifier and the `colonies` table. It's a
  research mode outside the bulletins: its results (colony counts, bleaching prevalence) are reported
  separately and **never mixed into the bulletin cover summaries**.
- **Diversity is reported both per transect and per station:** the number of distinct genus groups
  (TAUs) in each transect, and across the whole station. The station figure is what TB 2019-04's
  diversity grade (A–D) is applied to, until CCEF confirms how they count it.
- **Still to settle with CCEF:** the class-to-category mapping, the CMEMP/Agos template, and the
  agreement needed to accept Virtual and Preliminary modes against the physical frame.

## 11. What November 15 contributes

Use the **physical** frame on the dive so the data is standard. Where possible, also save the phone's
tilt reading with each still, and run the Measure-app test above on the frame (write the readings on
the slate). The ReefSight video pass on the same tapes (section 3, item 3) is also the first
comparison of preliminary video cover against photo-transect cover (section 7). Those photos, with a real 1 × 1 m frame in view, are the first calibration
and test set for the virtual frame.
