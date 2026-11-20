# Roadmap

Open work and loose ends. Remove an item when it's done; add new ones as they come up.

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
- **Following the simulated stock.** A rest pass that follows an operation models that operation's own settings
  exactly, but not what earlier passes before it removed. Following the simulated stock would cover chains of three or
  more tools.

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

- **Finish a neck on the FoxAlien** with a flat end mill along X and check the headstock transition for ridges and
  roughing steps.
- **One direction per operation.** A part with several differently curved areas gets the weighted average direction.
  Splitting the area into regions with their own direction (with machine-only regions today, by hand) would suit
  bodies with carves running different ways.
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

- **Tooltips on key settings.** Hover help on the inspector's and tool library's main parameters (stepover, stepdown,
  stock to leave, boundary, chip load, tabs, trench and so on): what each value does and a sensible range.
- **Machine control: a built-in G-code sender with a web UI.** A modern sender in the spirit of Universal G-code
  Sender, served by Swarf's own web server so any browser on the local network (e.g. a MacBook in the garage) can drive
  the machine. The Mac running Swarf talks to the FoxAlien (GRBL) over its USB serial port. Needs:
  - serial link to GRBL (USB CDC/CH340 driver, 115200 baud), streaming with character-counting flow control, status
    polling (`?`), feed hold / resume / soft reset, alarms and unlock;
  - jog, homing, set work zero (X/Y/Z, probe), spindle and feed/spindle overrides;
  - load the files Swarf exported (one per tool) and run them in order, with a tool-change pause between them;
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
