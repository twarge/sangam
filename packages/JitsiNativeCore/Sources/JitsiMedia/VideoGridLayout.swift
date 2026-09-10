import CoreGraphics

/// How a set of equally sized video tiles packs into the space a meeting
/// stage has for them.
///
/// Tiles keep the shape of the feeds they carry instead of stretching to
/// fill the stage, so the packing picks the column count whose tiles come
/// out largest. On a tall window that means few columns and tiles bounded
/// by the stage's width; on a short or wide one it means more columns and
/// tiles bounded by its height. Every row fits on screen either way — the
/// grid never runs off the bottom edge.
public struct VideoGridLayout: Equatable, Sendable {
  /// Tiles per row.
  public let columns: Int
  /// Rows needed to hold every tile.
  public let rows: Int
  /// The size of a single tile.
  public let tile: CGSize
  /// The gap left between neighboring tiles.
  public let spacing: CGFloat

  /// The packed grid's own width: its columns plus the gaps between them.
  public var width: CGFloat {
    guard columns > 0 else { return 0 }
    return CGFloat(columns) * tile.width + CGFloat(columns - 1) * spacing
  }

  /// The packed grid's own height: its rows plus the gaps between them.
  public var height: CGFloat {
    guard rows > 0 else { return 0 }
    return CGFloat(rows) * tile.height + CGFloat(rows - 1) * spacing
  }

  /// Packs `count` tiles of shape `aspectRatio` (width over height) into
  /// `size`, leaving `spacing` between them.
  ///
  /// The result is the largest tile any column count can produce; ties go
  /// to the wider arrangement, which keeps two feeds side by side on a
  /// landscape display rather than stacking them.
  public static func packing(
    _ count: Int,
    into size: CGSize,
    aspectRatio: CGFloat = 16.0 / 9.0,
    spacing: CGFloat = 4
  ) -> VideoGridLayout {
    var best = VideoGridLayout(
      columns: max(count, 1),
      rows: count > 0 ? 1 : 0,
      tile: .zero,
      spacing: spacing
    )
    guard count > 0, size.width > 0, size.height > 0, aspectRatio > 0 else { return best }

    for columns in 1...count {
      let rows = (count + columns - 1) / columns
      let cellWidth = (size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
      let cellHeight = (size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
      guard cellWidth > 0, cellHeight > 0 else { continue }
      // Whichever edge runs out first sets the tile: the full width of the
      // feed on a tall stage, its full height on a short one.
      let width = min(cellWidth, cellHeight * aspectRatio)
      guard width >= best.tile.width else { continue }
      best = VideoGridLayout(
        columns: columns,
        rows: rows,
        tile: CGSize(width: width, height: width / aspectRatio),
        spacing: spacing
      )
    }
    return best
  }
}
