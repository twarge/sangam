import CoreGraphics
import Testing

@testable import JitsiMedia

/// Tiles are packed at the feed's own shape, so the arrangement has to
/// follow the stage's shape: a wide stage fits more columns, a tall one
/// fewer, and in both cases every row lands inside the stage.
private let widescreen = CGSize(width: 1600, height: 900)
private let portrait = CGSize(width: 900, height: 1600)

@Test
func packsFourTilesTwoByTwoOnAWidescreenStage() {
  let layout = VideoGridLayout.packing(4, into: widescreen)
  #expect(layout.columns == 2)
  #expect(layout.rows == 2)
  #expect(layout.width <= widescreen.width)
  #expect(layout.height <= widescreen.height)
}

@Test
func stacksTwoTilesOnATallStage() {
  // Side by side, two 16:9 feeds on a portrait stage would be a third the
  // size they are stacked.
  let stacked = VideoGridLayout.packing(2, into: portrait)
  #expect(stacked.columns == 1)
  #expect(stacked.rows == 2)

  let sideBySide = VideoGridLayout.packing(2, into: widescreen)
  #expect(sideBySide.columns == 2)
  #expect(sideBySide.rows == 1)
}

@Test
func keepsEveryRowOnScreen() {
  // The old fixed-height grid ran off the bottom once the rows stopped
  // fitting; no arrangement may do that, however cramped the stage.
  for count in 1...16 {
    for size in [widescreen, portrait, CGSize(width: 3000, height: 420)] {
      let layout = VideoGridLayout.packing(count, into: size)
      #expect(layout.height <= size.height + 0.01, "\(count) tiles in \(size)")
      #expect(layout.width <= size.width + 0.01, "\(count) tiles in \(size)")
      #expect(layout.columns * layout.rows >= count)
    }
  }
}

@Test
func tilesKeepTheFeedShape() {
  let layout = VideoGridLayout.packing(5, into: portrait, aspectRatio: 4.0 / 3.0)
  #expect(abs(layout.tile.width / layout.tile.height - 4.0 / 3.0) < 0.001)
}

@Test
func picksTheColumnCountWithTheLargestTiles() {
  // An ultrawide stage fits all four feeds in one row, larger than 2×2
  // would leave them.
  let stage = CGSize(width: 3000, height: 800)
  let layout = VideoGridLayout.packing(4, into: stage)
  #expect(layout.columns == 4)
  #expect(layout.rows == 1)
  // 2×2 on that same stage would run out of height first, at a tile this
  // much narrower.
  let twoRowTileWidth = (stage.height - layout.spacing) / 2 * 16.0 / 9.0
  #expect(layout.tile.width > twoRowTileWidth)
}

@Test
func survivesAStageWithNoRoom() {
  let empty = VideoGridLayout.packing(3, into: .zero)
  #expect(empty.tile == .zero)
  #expect(VideoGridLayout.packing(0, into: widescreen).tile == .zero)
}
