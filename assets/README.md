# Marker art

The seven marker glyphs here are the shipped art. Nothing regenerates them, so a
replacement has to meet these by hand.

- 64x64 sheet, one file per glyph, named as render/markers.lua asks for it.
- White body (255,255,255) inside a near-black outline (10,10,10). set_color
  multiplies, so a pure black body would be erased and a body that is not white
  will not take the state colour.
- Fitted to the ink box bang.png and query.png occupy: bang inks 17x39 and query
  32x40 inside the sheet, both centred near y=31, about 62% of its height. A
  glyph that fills its own sheet renders visibly larger than those two.
