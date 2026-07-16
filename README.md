# A Family Across Two Centuries

A website for the Thompson / Ingleby family tree. Every fact on it is derived from
the Ancestry GEDCOM export — nothing is typed in by hand, and nothing is inferred.

**Live site:** _(GitHub Pages URL goes here once enabled)_

## The rule

> Everything that has held up came from an original record image.
> Everything that misled came from a hint or someone else's tree.

The site is built to hold to that:

- A record's label comes from the collection it was cited from — "1921 Census — Hunslet",
  not a generic "Census". Its page reference (`RG 15/22216, ED 5, Sch 321`) is shown too.
- A place only gets a map pin if it resolves in the curated gazetteer (`data/places.json`).
  County-only strings like "Yorkshire, England" are deliberately **not** pinned — a county
  has no honest point on a map. Unresolved places are reported, never guessed at.
- No death year without a death record.
- Journal chapters are attached to people by an **explicit tag**, never by matching names
  (see below).

## Privacy

The published build **redacts anyone who may still be living**: no death record and born
within the last 100 years. Their name and relationships remain so the tree still connects;
their dates, places, occupations, records and map pins are stripped **at build time** and
never reach the published file.

The raw GEDCOM is git-ignored and is never committed.

## Build

No Node or Python — PowerShell only.

```powershell
# 1. drop a fresh Ancestry export in src/thompson_tree.ged, then:
pwsh tools/Parse-Gedcom.ps1        # GEDCOM  -> data/gedcom.json
pwsh tools/Build-FamilyData.ps1    # + journals + gazetteer -> familydata.js
pwsh tools/Build-Preview.ps1       # standalone local preview (FULL data)

# publish
pwsh tools/Build-Site.ps1          # -> docs/  (living people redacted)
pwsh tools/Build-Site.ps1 -Private # -> docs/  (full data, local only)

# audit the tree itself
pwsh tools/Find-Problems.ps1       # duplicates, missing vitals, bad places

# prove nothing in the sources was lost on the way to the site
# (Build-Site runs this automatically and refuses to publish if it fails)
pwsh tools/Verify-Content.ps1      # story lines, chapters, events, citations
```

`Family Tree.dc.html` is a Claude design component: it uses React but never loads it,
because the claude.ai design host injects React for it. `Build-Preview` / `Build-Site` add
the two script tags so the page runs anywhere.

## Linking journal chapters to people

Names cannot be matched safely. "William Thompson" appears 58 times across the journals
and three different men carry that name; "Mary Jane Nicholson" appears *zero* times (she is
only ever "Mary Jane Blowman, ?née Nicholson"); and much of the prose is about people who
were **ruled out** — the strongest-scoring passage for Robert Dixon is the one proving a man
is *not* him.

So chapters are tagged explicitly, on the line after a heading:

```markdown
## Part One — Elizabeth Collins: the pit widow who married twice
<!-- ft: about=I352794087002 mentions=I352793886395,I352793885637 -->

### The Champion who was not our Champion
<!-- ft: decoy=true -->
```

| key | meaning |
|---|---|
| `about=` | the section **is about** them → shown on their profile as "Their story" |
| `mentions=` | a passing reference → shown as "Mentioned" |
| `decoy=true` | a **rejected** identification → linked to nobody |

IDs are Ancestry person IDs: `I` + the number in the Ancestry person URL. Untagged sections
simply do not link. The build reports any tagged ID that is not in the tree.

**Merge duplicates on Ancestry before tagging** — a merge retires one of the two IDs and you
don't get to choose which.

## Layout

```
tools/    the build (PowerShell)
data/     gazetteer, diary manifest, generated reports
src/      the GEDCOM export  (git-ignored)
img/      photos
vendor/   Leaflet (vendored — no CDN dependency)
docs/     the published site
```
