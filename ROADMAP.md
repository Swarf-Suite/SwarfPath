# Roadmap

Open work and loose ends. Remove an item when it's done; add new ones as they come up.


## The Swarf Suite

SwarfPath (was Swarf) now lives at [Swarf-Suite/SwarfPath](https://github.com/Swarf-Suite/SwarfPath), beside
[SwarfGRBL](https://github.com/Swarf-Suite/SwarfGRBL) (the sender, was KerfLine) and
[SwarfEngrave](https://github.com/Swarf-Suite/SwarfEngrave) (planned: V-carve design and G-code).

- ✅ Renamed: app, bundle id (`io.github.swarf-suite.swarfpath`), targets, `swarfpath-cli`, the user guide. Settings
  and the tool library move across on first launch; the `.swarf` document type is unchanged.
- ⬜ Share the engine with SwarfEngrave: move what both need from `CAMCore` (tools and tool library, post-processors,
  `GCodeHub`, the V-carve toolpath code) into a package both depend on, as SwarfEngrave's roadmap describes.

## Two-sided machining

Two-sided (flip) machining is in: dowel holes, side A, a roll about X, then side B (`Flip.swift`). Loose ends:

- **Run a flip job on the machine.** Check three things:
  - The dowel holes line up after the roll.
  - Side-B cavities land where the model has them.
  - Re-probing Z on the new top is enough.

  The tests prove the geometry, but not the clamping or the real-world registration.
- **Side-B keep-outs in the 3D view.** Keep-outs can apply to side A, side B or both (`Region.sides`). They are all
  drawn in the side-A top view, mirrored for side B. A view of the back as it sits on the machine would make clamp
  positions easier to place.
- **Necks.** Necks are thick (often over 45 mm with the headstock), so the dowel depth limit bites. Consider dowels
  that go only partway through the stock, or a shorter spoilboard depth.
- **Facing on side B.** It isn't offered (the user doesn't want it), but a blank thicker than the part relies on
  side-B pocketing or roughing to bring the back down.

## Accuracy

- **Exact walls on sloped material.** Pockets, 3D roughing and waterline put every wall pass on the exact offset with
  `ToolFootprint` (Silhouette.swift), which splits a ball, bull-nose or V-bit into height bands. That is exact where
  the cutter meets a vertical wall with its full width; against sloped material it keeps the grid contour of the exact
  cutter dilation (about a cell). A true contact-height solve (the cutter profile against each triangle) would close
  that gap.
- **V-carve path off the centre line.** V-carve depths on recesses are exact for where the path runs, but the medial
  axis comes from the grid, so in a narrow slot the path can sit a fraction of a cell off centre and the carve ends up
  that much shallower than ideal (about 0.1 mm on a 10 mm slot with a 60° bit).

## Rest machining

Rest machining is in (`Rest.swift`): a smaller tool cuts only what a larger one left. Loose ends:

- **Cut a rest pass on the machine** with a real small bit, and measure its flute length and shank. The starter values
  for the 2 mm, 1 mm and 0.9 mm bits are typical, not measured.
- **Uncut stock and the shank.** The shank is kept off the model, but not off leftover material that this tool itself
  can't reach. That needs leftover deep beside a wall within a shank radius of where the bit cuts; it hasn't come up in
  tests.
- **Following the simulated stock** is in ("Everything before it", `Leftover.swift`) and is Full Processing's default.
  It simulates every earlier operation each time one changes; on a big job that may get slow in the app. Auto Plan's
  own rest passes still use `restFromOp`.
- **Cut a near-fit slot on the machine.** The 6 mm flat now cuts the neck's 6.2 mm truss-rod channel on its centre line
  (`Slots.swift`) with 0.1 mm either side. Check the real width, and whether bit runout makes it rub or chatter.
- **Slot operation** (`SlotMilling.swift`): slots a flat fits exactly (D to D + `widthTolerance`), cut down the centre
  line with wall passes where wider. Full Processing adds one per smaller library flat that finds slots. Loose ends:
  - Each slot's points are ordered along one main axis, so an L-shaped or curved slot is split where the order
    zig-zags and may lose its corner. Chain the points instead.
  - Detection runs a distance transform per level and the exact search only on ridge cells (slot centres); about
    0.2 s on an 80 mm test plate. It runs once per library flat in Full Processing, so time it on a big library.
  - Slots are found at their floor and cut whole from the top down. A slot with a stepped floor gets one run per step,
    each from the top, so the shallow part's air is cut twice.
  - Cut a 4 mm slot with the 4 mm bit on the machine: full-width slotting at half-diameter stepdown and the
    calculator's feed. Check chip clearing and whether the feed should drop for slotting.
- **Slot passes are flat-bottomed pocket passes only.** A slot that narrows below a ball or bull nose's full width, or a
  roughing op, still falls back to a smaller bit.

## Cutout trench

The wide trench is in (`cutout` in Operations.swift, `CutoutTrench` in Job.swift). Loose ends:

- **Cut one on the FoxAlien** and see whether chips really clear better, and whether a deeper stepdown is then safe.
- **Trench only where it's deep: not possible.** To cut the outer pass at depth, the cutter needs the whole trench
  above it cleared, so the outer pass has to start at the top. Time savings have to come from elsewhere.
- **Second-pass feed on the machine.** It runs at 1.25× by default (63 → 58 min on a guitar body). Find out how
  far it can really go on the FoxAlien.

## Finishing direction

Parallel finishes pick their direction from the surface, and roughing leaves enough for the finishes after it
(`FinishDirection.swift`). Loose ends:

- **Flat for the curve finish on every part?** Full Processing's "Finish (curves)" now uses the pocket's flat at 10%
  stepover, along the curve. That suits necks (curvature one way), but in concave coves a flat leaves R²/2r, and a dished
  patch curving both ways gets steps. Consider choosing the ball where the patch curves both ways.
- **Edge overrun on the machine.** Pockets carry on past open edges (`runsPastOpenEdges`). Check the waste it cuts
  outside the part doesn't weaken the stock where it's clamped.
- **Finish a neck on the FoxAlien** with a flat end mill along X and check the headstock transition for ridges and
  roughing steps.
- **Creases and slot walls are left out of the direction choice**, and with rest machining only the leftover material
  itself counts. Check a few more parts (bodies with carves) that the choice is still right.
- **One direction per operation.** A part with several differently curved areas gets the weighted average direction.
  Areas (⌥⌘A) now give a region its own finishing operation and direction, by hand; picking the areas
  automatically would suit bodies with carves running different ways.
- **Planning roughing generates the finish too.** Roughing is held up only where the finish's own toolpath, simulated,
  doesn't get below it, so the finish is generated twice (about 4 s more on the dome fixture). Caching the finish's
  toolpath in `CAMContext` would save that.

## Feeds and speeds

The chip-load calculator is in (`FeedsCalculator.swift`). Loose ends:

- **Check the chip-load table on the FoxAlien.** The ranges come from typical router-bit charts; tune them from real cuts.
- **Shallow ball nose depth is an estimate.** The calculator takes the depth you give it; the operation's chip-load check
  assumes the stepdown, or 0.5 mm for parallel finishing. The real depth on a parallel pass varies with the roughing left.
- **Machine Z speed.** Profiles have one max feed; plunge is capped by bit size and at 800 mm/min, not by the machine's Z limit.
- **Hogging on the machine.** Pockets leave 0.3 mm on walls and 3 mm on floors, and cutouts stop 3 mm above the stock
  bottom (`Operation.applyHogSkins`). Check on the FoxAlien that 3 mm is enough for a careless re-zero and not so much
  that the flat struggles, and that the flat's single ramp through the hogged slot's 0.2–0.3 mm wall skin cuts cleanly.
- **Stick-out is per tool, not per setup.** The collet warning uses the tool library's stick-out; if a bit is set
  further out for a deep job, the library has to be edited.

## App

- **Auto Plan on the machine.** Run an Auto Plan job with a rest pass (e.g. the slotted neck board: 1/4" clearing, 1/8"
  rest) on the FoxAlien as a SwarfGRBL file group, and check the run-time estimate against the real time.
- **Auto Plan choices.** It takes the biggest bit that reaches. A setting to prefer a bit (or to leave bits out of
  planning, such as ones that are worn) would help once real libraries grow.

- **Areas on the machine.** Cut a neck blank with a truss-rod slot area (1/8" bit) on the FoxAlien and check the slot
  is where the box says, and that SwarfGRBL shows the Z-zero badge SwarfPath's header gives.
- **Areas from features.** An area is a box drawn by hand. Picking a slot or pocket on the model (or a polygon area)
  would fit features that aren't rectangles or that run diagonally.

- **Tooltips on key settings.** Hover help on the inspector's and tool library's main parameters (stepover, stepdown,
  stock to leave, boundary, chip load, tabs, trench and so on): what each value does and a sensible range.
- **Machine control: a built-in G-code sender with a web UI.** A modern sender in the spirit of Universal G-code
  Sender, served by SwarfPath's own web server so any browser on the local network (e.g. a MacBook in the garage) can drive
  the machine. The Mac running SwarfPath talks to the FoxAlien (GRBL) over its USB serial port. Needs:
  - serial link to GRBL (USB CDC/CH340 driver, 115200 baud), streaming with character-counting flow control, status
    polling (`?`), feed hold / resume / soft reset, alarms and unlock;
  - jog, homing, set work zero (X/Y/Z, probe), spindle and feed/spindle overrides;
  - load the files SwarfPath exported (one per tool) and run them in order, with a tool-change pause between them;
  - live position, progress, and a toolpath preview in the browser;
  - LAN access with some protection (a pairing code or password; only one controlling client at a time), since
    anything that can reach the page can move the machine.
- **Check that the export file name is remembered.** Typing a name and the live rename were checked in the
  app. Saving the name with the project and reopening it were not.
- **Check `M3 P0` / `M5 P0` and rapids on a Duet (RRF) machine such as the WorkBee.** Run an exported file on the machine and confirm two
  things:
  - The "M3: No P parameter and no active tool with spindle" error is gone. If the Duet's `config.g` puts the
    spindle under a number other than 0 (the `R` value on its `M950` line), the RRF profiles need that number.
  - Rapids (`G0 … F5000`) now run at rapid speed rather than the cutting feed.
