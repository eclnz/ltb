/*
Package ui draws the viewer's chrome.

It knows about pixels, colours and text, and nothing about worlds, layers or
datasets. Everything above it -- the HUD, the menu bar, the file browser --
composes these pieces and never reaches for raylib's drawing calls directly, so
that a change to the palette or the text scale is a change in one file.

The one rule worth stating: a panel is measured from its contents, never from a
constant. `panel_begin` collects rows, `panel_end` sizes the box around what was
actually added and paints the background before the rows. Immediate-mode drawing
otherwise forces the caller to know the height of text it has not drawn yet,
which is how a background ends up one line short of the text on top of it.
*/
package ui

import rl "vendor:raylib"

// ---------------------------------------------------------------------------
// Palette
// ---------------------------------------------------------------------------

// The ground the map is drawn on, and what the window shows when there is no
// map to draw.
BACKGROUND :: rl.Color{14, 16, 20, 255}

// Surfaces, darkest first.
FIELD :: rl.Color{18, 20, 25, 255} // Inside of a list or a text box.
BAR :: rl.Color{22, 24, 30, 240} // The menu bar.
SURFACE :: rl.Color{28, 31, 38, 252} // Drop-downs and modal panels.
CONTROL :: rl.Color{48, 53, 64, 255} // Buttons at rest.

// Panels laid over the map are translucent: the map is the point, and a HUD
// that hides it is a HUD in the way.
PANEL :: rl.Color{0, 0, 0, 150}
// Dims the map behind a modal, so the modal reads as modal.
SCRIM :: rl.Color{0, 0, 0, 140}

BORDER :: rl.Color{70, 76, 90, 255}
BORDER_DIM :: rl.Color{60, 66, 78, 255}
CONTROL_BORDER :: rl.Color{80, 88, 104, 255}

HIGHLIGHT :: rl.Color{58, 92, 148, 255} // Selected row, open menu, hovered button.
ROW_HOVER :: rl.Color{44, 49, 60, 255}
SCROLLBAR :: rl.Color{90, 98, 115, 255}

// Text, brightest first.
TEXT :: rl.Color{245, 245, 245, 255}
TEXT_DIM :: rl.Color{200, 200, 200, 255}
TEXT_MUTED :: rl.Color{150, 160, 180, 255}
TEXT_FAINT :: rl.Color{130, 138, 152, 255}
TEXT_OFF :: rl.Color{120, 126, 138, 255} // Disabled.

// Meaning, not decoration: these say what state something is in.
OK :: rl.Color{140, 215, 150, 255}
WARN :: rl.Color{220, 190, 140, 255}
ALERT :: rl.Color{235, 170, 160, 255}
LINK :: rl.Color{150, 190, 235, 255} // Directories, and anything that navigates.

// The hover cursor drawn on the map itself.
CURSOR :: rl.Color{255, 255, 255, 200}

// ---------------------------------------------------------------------------
// Text scale
// ---------------------------------------------------------------------------

// Six sizes, and no others. A seventh size chosen to make one label fit is the
// beginning of a HUD that no longer looks like one thing.
TITLE :: 20
HEADING :: 16
BODY :: 14
LABEL :: 13
SMALL :: 12
TINY :: 11

// Vertical space added to a line's size to give the next line its baseline.
LEADING :: 5

// Height of one row in a scrolling list.
ROW_H :: 19
