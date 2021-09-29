# NOTES
# - @tiles has the extra tile hanging off the left/top of the screen, because
#   the pixel offset values are positive and added to the coordinates.

# - An alternative to rearranging @tiles in def check_if_screen_moved would
#   be to have extra variables that determine how much the @tiles array has
#   wrapped around (e.g. 1 means the tile sprites should be 1 tile further right
#   or down than their indices in the array would suggest). This would be more
#   convenient if I also have an array of x/y/layer triplets marking tile
#   sprites using autotiles with 2+ frames.

#===============================================================================
#
#===============================================================================
class TilemapRenderer
  attr_reader   :tilesets
  attr_reader   :autotiles
  attr_reader   :graphics_width
  attr_reader   :graphics_height
  attr_accessor :tone
  attr_accessor :color
  attr_reader   :viewport
  # TODO: ox, oy and visible don't do anything. Should they?
  attr_accessor :ox
  attr_accessor :oy
  attr_accessor :visible

  DISPLAY_TILE_WIDTH  = Game_Map::TILE_WIDTH rescue 32
  DISPLAY_TILE_HEIGHT = Game_Map::TILE_HEIGHT rescue 32
  SOURCE_TILE_WIDTH   = 32
  SOURCE_TILE_HEIGHT  = 32

  # If an autotile's filename ends with [x], its frame duration will be x/20
  # seconds instead.
  AUTOTILE_FRAME_DURATION = 5   # In 1/20ths of a second

  TILESET_TILES_PER_ROW = 8
  AUTOTILES_COUNT       = 8   # Counting the blank tile as an autotile
  TILES_PER_AUTOTILE    = 48
  TILESET_START_ID      = AUTOTILES_COUNT * TILES_PER_AUTOTILE

  # TODO: Flash duration is hardcoded to 0.05 seconds per "frame". However, this
  #       kind of flash is unused, but it should be supported anyway.
  FLASH_OPACITY = [100, 90, 80, 70, 80, 90]

  #=============================================================================
  #
  #=============================================================================
  class TilesetBitmaps
    attr_accessor :changed
    attr_accessor :bitmaps

    def initialize
      @bitmaps      = {}
      @bitmap_wraps = {}   # Whether each tileset is a mega texture and has multiple columns
      @load_counts  = {}
      @changed      = true
    end

    def [](filename)
      return @bitmaps[filename]
    end

    def []=(filename, bitmap)
      return if nil_or_empty?(filename)
      @bitmaps[filename] = bitmap
      @bitmap_wraps[filename] = false
      @changed = true
    end

    def add(filename)
      return if nil_or_empty?(filename)
      if @bitmaps[filename]
        @load_counts[filename] += 1
        return
      end
      bitmap = pbGetTileset(filename)
      @bitmap_wraps[filename] = false
      if bitmap.mega?
        self[filename] = TileWrap::wrapTileset(bitmap)
        @bitmap_wraps[filename] = true
        bitmap.dispose
      else
        self[filename] = bitmap
      end
      @load_counts[filename] = 1
    end

    def remove(filename)
      return if nil_or_empty?(filename) || !@bitmaps[filename]
      if @load_counts[filename] > 1
        @load_counts[filename] -= 1
        return
      end
      @bitmaps[filename].dispose
      @bitmaps.delete(filename)
      @bitmap_wraps.delete(filename)
      @load_counts.delete(filename)
    end

    def set_src_rect(tile, tile_id)
      return if nil_or_empty?(tile.filename)
      return if !@bitmaps[tile.filename]
      tile.src_rect.x = ((tile_id - TILESET_START_ID) % TILESET_TILES_PER_ROW) * SOURCE_TILE_WIDTH
      tile.src_rect.y = ((tile_id - TILESET_START_ID) / TILESET_TILES_PER_ROW) * SOURCE_TILE_HEIGHT
      if @bitmap_wraps[tile.filename]
        height = @bitmaps[tile.filename].height
        col = (tile_id - TILESET_START_ID) * SOURCE_TILE_HEIGHT / height
        tile.src_rect.x += col * AUTOTILES_COUNT * SOURCE_TILE_WIDTH
        tile.src_rect.y -= col * height
      end
    end

    def update; end
  end

  #=============================================================================
  #
  #=============================================================================
  class AutotileBitmaps < TilesetBitmaps
    attr_reader :current_frames

    def initialize
      super
      @frame_counts    = {}   # Number of frames in each autotile
      @frame_durations = {}   # How long each frame lasts per autotile
      @current_frames  = {}   # Which frame each autotile is currently showing
      @timer           = 0.0
    end

    def []=(filename, value)
      super
      return if nil_or_empty?(filename)
      frame_count(filename, true)
      set_current_frame(filename)
    end

    def add(filename)
      return if nil_or_empty?(filename)
      if @bitmaps[filename]
        @load_counts[filename] += 1
        return
      end
      orig_bitmap = pbGetAutotile(filename)
      @bitmap_wraps[filename] = false
      duration = AUTOTILE_FRAME_DURATION
      if filename[/\[\s*(\d+?)\s*\]\s*$/]
        duration = $~[1].to_i
      end
      @frame_durations[filename] = duration.to_f / 20
      bitmap = AutotileExpander.expand(orig_bitmap)
      self[filename] = bitmap
      if bitmap.height > SOURCE_TILE_HEIGHT && bitmap.height < TILES_PER_AUTOTILE * SOURCE_TILE_HEIGHT
        @bitmap_wraps[filename] = true
      end
      orig_bitmap.dispose if orig_bitmap != bitmap
      @load_counts[filename] = 1
    end

    def remove(filename)
      super
      return if @load_counts[filename] && @load_counts[filename] > 0
      @frame_counts.delete(filename)
      @current_frames.delete(filename)
      @frame_durations.delete(filename)
    end

    def frame_count(filename, force_recalc = false)
      if !@frame_counts[filename] || force_recalc
        return 0 if !@bitmaps[filename]
        bitmap = @bitmaps[filename]
        @frame_counts[filename] = [bitmap.width / SOURCE_TILE_WIDTH, 1].max
        if bitmap.height > SOURCE_TILE_HEIGHT && @bitmap_wraps[filename]
          @frame_counts[filename] /= 2 if @bitmap_wraps[filename]
        end
      end
      return @frame_counts[filename]
    end

    def animated?(filename)
      return frame_count(filename) > 1
    end

    def current_frame(filename)
      if !@current_frames[filename]
        set_current_frame(filename)
      end
      return @current_frames[filename]
    end

    def set_current_frame(filename)
      frames = frame_count(filename)
      if frames < 2
        @current_frames[filename] = 0
      else
        @current_frames[filename] = (@timer / @frame_durations[filename]).floor % frames
      end
    end

    def set_src_rect(tile, tile_id)
      return if nil_or_empty?(tile.filename)
      return if !@bitmaps[tile.filename]
      return if tile_id < TILES_PER_AUTOTILE   # Blank tile
      frame = current_frame(tile.filename)
      if @bitmaps[tile.filename].height == SOURCE_TILE_HEIGHT
        tile.src_rect.x = frame * SOURCE_TILE_WIDTH
        tile.src_rect.y = 0
        return
      end
      wraps = @bitmap_wraps[tile.filename]
      high_id = ((tile_id % TILES_PER_AUTOTILE) >= TILES_PER_AUTOTILE / 2)
      tile.src_rect.x = 0
      tile.src_rect.y = (tile_id % TILES_PER_AUTOTILE) * SOURCE_TILE_HEIGHT
      if wraps && high_id
        tile.src_rect.x = SOURCE_TILE_WIDTH
        tile.src_rect.y -= SOURCE_TILE_HEIGHT * TILES_PER_AUTOTILE / 2
      end
      tile.src_rect.x += frame * SOURCE_TILE_WIDTH * (wraps ? 2 : 1)
    end

    def update
      super
      @timer += Graphics.delta_s
      # Update the current frame for each autotile
      @bitmaps.keys.each do |filename|
        next if !@bitmaps[filename] || @bitmaps[filename].disposed?
        old_frame = @current_frames[filename]
        set_current_frame(filename)
        @changed = true if @current_frames[filename] != old_frame
      end
    end
  end

  #=============================================================================
  #
  #=============================================================================
  class TileSprite < Sprite
    attr_accessor :filename
    attr_accessor :is_autotile
    attr_accessor :animated
    attr_accessor :priority
    attr_accessor :shows_reflection
    attr_accessor :bridge
    attr_accessor :need_refresh

    def set_bitmap(filename, autotile, animated, priority, bitmap)
      self.bitmap       = bitmap
      self.src_rect     = Rect.new(0, 0, DISPLAY_TILE_WIDTH, DISPLAY_TILE_HEIGHT)
      @filename         = filename
      @is_autotile      = autotile
      @animated         = animated
      @priority         = priority
      @shows_reflection = false
      @bridge           = false
      self.visible      = !bitmap.nil?
      @need_refresh     = true
    end
  end

  #=============================================================================
  #
  #=============================================================================
  def initialize(viewport)
    @tilesets                = TilesetBitmaps.new
    @autotiles               = AutotileBitmaps.new

    @can_query_graphics_size = (Graphics.width != nil rescue false)
    if @can_query_graphics_size
      @graphics_width        = Graphics.width
      @graphics_height       = Graphics.height
    else
      @graphics_width        = 640
      @graphics_height       = 480
    end

    @tiles_horizontal_count = (@graphics_width.to_f / DISPLAY_TILE_WIDTH).ceil + 1
    @tiles_vertical_count   = (@graphics_height.to_f / DISPLAY_TILE_HEIGHT).ceil + 1

    @tone                    = Tone.new(0, 0, 0, 0)
    @old_tone                = Tone.new(0, 0, 0, 0)
    @color                   = Color.new(0, 0, 0, 0)
    @old_color               = Color.new(0, 0, 0, 0)

    @self_viewport           = Viewport.new(0, 0, graphics_width, graphics_height)
    @viewport                = (viewport) ? viewport : @self_viewport
    @old_viewport_ox         = 0
    @old_viewport_oy         = 0

    @tiles                   = []
    @tiles_horizontal_count.times do |i|
      @tiles[i] = []
      @tiles_vertical_count.times do |j|
        @tiles[i][j]         = Array.new(3) { TileSprite.new(@viewport) }
      end
    end

    @current_map_id          = 0
    @tile_offset_x           = 0
    @tile_offset_y           = 0
    @pixel_offset_x          = 0
    @pixel_offset_y          = 0

    @ox                      = 0      # Bitmap Offsets
    @oy                      = 0      # Bitmap Offsets

    @visible                 = true

    @flash                   = nil
    @oxFlash                 = 0
    @oyFlash                 = 0
    @flashChanged            = false
    @firsttimeflash          = true

    @disposed                = false
  end

  def dispose
    return if disposed?
    @tiles.each do |col|
      col.each do |coord|
        coord.each { |tile| tile.dispose }
      end
    end
    if @flash
      @flash.bitmap.dispose if !@flash.disposed?
      @flash.bitmap = nil if !@flash.disposed?
      @flash.dispose
      @flash = nil
    end
    @tilesets.bitmaps.each_value { |bitmap| bitmap.dispose }
    @autotiles.bitmaps.each_value { |bitmap| bitmap.dispose }
    @self_viewport.dispose
    @self_viewport = nil
    @disposed = true
  end

  def disposed?
    return @disposed
  end

  #=============================================================================

  def add_tileset(filename)
    @tilesets.add(filename)
  end

  def remove_tileset(filename)
    @tilesets.remove(filename)
  end

  def add_autotile(filename)
    @autotiles.add(filename)
  end

  def remove_autotile(filename)
    @autotiles.remove(filename)
  end

  #=============================================================================

  # TODO: Flash stuff, including usage of flash_data.
  def refresh_flash
    if @flash_data && !@flash
      @flash = TileSprite.new(viewport)
      @flash.visible    = true
      @flash.z          = 1
      @flash.tone       = tone
      @flash.color      = color
      @flash.blend_type = 1
      @flash.bitmap     = Bitmap.new([graphics_width * 2, 1].max, [graphics_height * 2, 1].max)
      @firsttimeflash = true
    elsif !@flash_data && @flash
      @flash.bitmap.dispose if @flash.bitmap
      @flash.dispose
      @flash = nil
      @firsttimeflash = false
    end
  end

  def refreshFlashSprite
    return if !@flash || @flash_data.nil?
    ptX = @ox-@oxFlash
    ptY = @oy-@oyFlash
    if !@firsttimeflash &&
       ptX>=0 && ptX+@viewport.rect.width<=@flash.bitmap.width &&
       ptY>=0 && ptY+@viewport.rect.height<=@flash.bitmap.height
      @flash.ox = 0
      @flash.oy = 0
      @flash.src_rect.set(ptX.round,ptY.round,
         @viewport.rect.width,@viewport.rect.height)
      return
    end
    width = @flash.bitmap.width
    height = @flash.bitmap.height
    bitmap = @flash.bitmap
    ysize = @map_data.ysize
    xsize = @map_data.xsize
    @firsttimeflash = false
    @oxFlash = @ox-(width>>2)
    @oyFlash = @oy-(height>>2)
    @flash.ox = 0
    @flash.oy = 0
    @flash.src_rect.set(width>>2,height>>2,
       @viewport.rect.width,@viewport.rect.height)
    @flash.bitmap.clear
    @oxFlash = @oxFlash.floor
    @oyFlash = @oyFlash.floor
    xStart = @oxFlash / DISPLAY_TILE_WIDTH
    xStart = 0 if xStart<0
    yStart = @oyFlash / DISPLAY_TILE_HEIGHT
    yStart = 0 if yStart<0
    xEnd = xStart + (width / DISPLAY_TILE_WIDTH) + 1
    yEnd = yStart + (height / DISPLAY_TILE_HEIGHT) + 1
    xEnd = xsize if xEnd>=xsize
    yEnd = ysize if yEnd>=ysize
    if xStart<xEnd && yStart<yEnd
      yrange = yStart...yEnd
      xrange = xStart...xEnd
      tmpcolor = Color.new(0,0,0,0)
      for y in yrange
        ypos = (y * DISPLAY_TILE_HEIGHT) - @oyFlash
        for x in xrange
          xpos = (x * DISPLAY_TILE_WIDTH) - @oxFlash
          id = @flash_data[x, y, 0]
          r = (id>>8)&15
          g = (id>>4)&15
          b = (id)&15
          tmpcolor.set(r<<4,g<<4,b<<4)
          bitmap.fill_rect(xpos, ypos, DISPLAY_TILE_WIDTH, DISPLAY_TILE_HEIGHT, tmpcolor)
        end
      end
    end
  end

  #=============================================================================

  def refresh(autotiles = false)
    refreshFlashSprite
  end

  #=============================================================================

  def refresh_tile_bitmap(tile, map, tile_id)
    if tile_id < TILES_PER_AUTOTILE
      tile.set_bitmap("", false, false, 0, nil)
      tile.shows_reflection = false
      tile.bridge           = false
    else
      terrain_tag = map.terrain_tags[tile_id] || 0
      terrain_tag_data = GameData::TerrainTag.try_get(terrain_tag)
      priority = map.priorities[tile_id] || 0
      if tile_id < TILESET_START_ID
        filename = map.autotile_names[tile_id / TILES_PER_AUTOTILE - 1]
        tile.set_bitmap(filename, true, @autotiles.animated?(filename),
           priority, @autotiles[filename])
      else
        filename = map.tileset_name
        tile.set_bitmap(filename, false, false, priority, @tilesets[filename])
      end
      tile.shows_reflection = terrain_tag_data&.shows_reflections
      tile.bridge           = terrain_tag_data&.bridge
    end
    refresh_tile_src_rect(tile, tile_id)
  end

  def refresh_tile_src_rect(tile, tile_id)
    if tile_id < TILESET_START_ID
      @autotiles.set_src_rect(tile, tile_id)
    else
      @tilesets.set_src_rect(tile, tile_id)
    end
  end

  # For animated autotiles only
  def refresh_tile_frame(tile, tile_id)
    return if !tile.animated
    @autotiles.set_src_rect(tile, tile_id)
  end

  # x and y are the positions of tile within @tiles, not a map x/y
  def refresh_tile_coordinates(tile, x, y)
    tile.x = x * DISPLAY_TILE_WIDTH - @pixel_offset_x
    tile.y = y * DISPLAY_TILE_HEIGHT - @pixel_offset_y
  end

  def refresh_tile_z(tile, map, y, layer, tile_id)
    if tile.shows_reflection
      tile.z = -100
    elsif tile.bridge && $PokemonGlobal.bridge > 0
      tile.z = 0
    else
      priority = tile.priority
      tile.z = (priority == 0) ? 0 : y * DISPLAY_TILE_HEIGHT + priority * 32 + 32
    end
  end

  def refresh_tile(tile, x, y, map, layer, tile_id)
    refresh_tile_bitmap(tile, map, tile_id)
    refresh_tile_coordinates(tile, x, y)
    refresh_tile_z(tile, map, y, layer, tile_id)
    tile.need_refresh = false
  end

  #=============================================================================

  def check_if_screen_moved
    ret = false
    # Check for map change
    if @current_map_id != $game_map.map_id
      if MapFactoryHelper.hasConnections?(@current_map_id)
        offsets = $MapFactory.getRelativePos(@current_map_id, 0, 0, $game_map.map_id, 0, 0)
        if offsets
          @tile_offset_x += offsets[0]
          @tile_offset_y += offsets[1]
        else
          ret = true   # Need a full refresh
        end
      end
      @current_map_id = $game_map.map_id
      ret = true
    end

    # Check for tile movement
    current_map_display_x = ($game_map.display_x.to_f / Game_Map::X_SUBPIXELS).round
    current_map_display_y = ($game_map.display_y.to_f / Game_Map::Y_SUBPIXELS).round
    new_tile_offset_x = current_map_display_x / DISPLAY_TILE_WIDTH
    new_tile_offset_y = current_map_display_y / DISPLAY_TILE_HEIGHT
    if new_tile_offset_x != @tile_offset_x
      if new_tile_offset_x > @tile_offset_x
        # Take tile stacks off the right and insert them at the beginning (left)
        (new_tile_offset_x - @tile_offset_x).times do
          c = @tiles.shift
          @tiles.push(c)
          c.each do |coord|
            coord.each { |tile| tile.need_refresh = true }
          end
        end
      else
        # Take tile stacks off the beginning (left) and push them onto the end (right)
        (@tile_offset_x - new_tile_offset_x).times do
          c = @tiles.pop
          @tiles.prepend(c)
          c.each do |coord|
            coord.each { |tile| tile.need_refresh = true }
          end
        end
      end
      @screen_moved = true
      @tile_offset_x = new_tile_offset_x
    end
    if new_tile_offset_y != @tile_offset_y
      if new_tile_offset_y > @tile_offset_y
        # Take tile stacks off the bottom and insert them at the beginning (top)
        @tiles.each do |col|
          (new_tile_offset_y - @tile_offset_y).times do
            c = col.shift
            col.push(c)
            c.each { |tile| tile.need_refresh = true }
          end
        end
      else
        # Take tile stacks off the beginning (top) and push them onto the end (bottom)
        @tiles.each do |col|
          (@tile_offset_y - new_tile_offset_y).times do
            c = col.pop
            col.prepend(c)
            c.each { |tile| tile.need_refresh = true }
          end
        end
      end
      @screen_moved = true
      @screen_moved_vertically = true
      @tile_offset_y = new_tile_offset_y
    end

    # Check for pixel movement
    new_pixel_offset_x = current_map_display_x % SOURCE_TILE_WIDTH
    new_pixel_offset_y = current_map_display_y % SOURCE_TILE_HEIGHT
    if new_pixel_offset_x != @pixel_offset_x
      @screen_moved = true
      @pixel_offset_x = new_pixel_offset_x
    end
    if new_pixel_offset_y != @pixel_offset_y
      @screen_moved = true
      @screen_moved_vertically = true
      @pixel_offset_y = new_pixel_offset_y
    end
    return ret
  end

  #=============================================================================

  def update
    # Check if screen was resized
    # TODO: If it was resized, change how many TileSprites there are.
    #       CustomTilemap only uses this for the flash graphic.
    if @can_query_graphics_size
      @graphics_width  = Graphics.width
      @graphics_height = Graphics.height
    end
    # Update tone
    if @old_tone != @tone
      @flash.tone = @tone if @flash
      @tiles.each do |col|
        col.each do |coord|
          coord.each { |tile| tile.tone = @tone }
        end
      end
      @old_tone = @tone.clone
    end
    # Update color
    if @old_color != @color
      @flash.color = @color if @flash
      @tiles.each do |col|
        col.each do |coord|
          coord.each { |tile| tile.color = @tone }
        end
      end
      @old_color = @color.clone
    end
    # Recalculate autotile frames
    @tilesets.update
    @autotiles.update

    # Update flash
    refresh_flash if @flashChanged
    @flash.opacity = FLASH_OPACITY[(Graphics.frame_count / 2) % 6] if @flash

    do_full_refresh = false
    if @viewport.ox != @old_viewport_ox || @viewport.oy != @old_viewport_oy
      @old_viewport_ox = @viewport.ox
      @old_viewport_oy = @viewport.oy
      do_full_refresh = true
    end

    # Check whether the screen has moved since the last update
    @screen_moved = false
    @screen_moved_vertically = false
    do_full_refresh = true if check_if_screen_moved

    # Update all tile sprites
    visited = []
    @tiles_horizontal_count.times do |i|
      visited[i] = []
      @tiles_vertical_count.times { |j| visited[i][j] = false }
    end

    $MapFactory.maps.each do |map|
      # Calculate x/y ranges of tile sprites that represent them
      map_display_x = (map.display_x.to_f / Game_Map::X_SUBPIXELS).round
      map_display_y = (map.display_y.to_f / Game_Map::Y_SUBPIXELS).round
      map_display_x_tile = map_display_x / DISPLAY_TILE_WIDTH
      map_display_y_tile = map_display_y / DISPLAY_TILE_HEIGHT
      start_x = [-map_display_x_tile, 0].max
      start_y = [-map_display_y_tile, 0].max
      end_x = @tiles_horizontal_count - 1
      end_x = [end_x, map.width - map_display_x_tile - 1].min
      end_y = @tiles_vertical_count - 1
      end_y = [end_y, map.height - map_display_y_tile - 1].min
      next if start_x > end_x || start_y > end_y || end_x < 0 || end_y < 0

      # Update all tile sprites representing this map
      for i in start_x..end_x
        tile_x = i + map_display_x_tile
        for j in start_y..end_y
          tile_y = j + map_display_y_tile
          @tiles[i][j].each_with_index do |tile, layer|
            tile_id = map.data[tile_x, tile_y, layer]
            if do_full_refresh || tile.need_refresh
              refresh_tile(tile, i, j, map, layer, tile_id)
            else
              refresh_tile_frame(tile, tile_id) if tile.animated && @autotiles.changed
              # Update tile's x/y coordinates
              refresh_tile_coordinates(tile, i, j) if @screen_moved
              # Update tile's z value
              refresh_tile_z(tile, map, j, layer, tile_id) if @screen_moved_vertically
            end
          end
          # Record x/y as visited
          visited[i][j] = true
        end
      end
    end

    # Clear all unvisited tile sprites
    @tiles.each_with_index do |col, i|
      col.each_with_index do |coord, j|
        next if visited[i][j]
        coord.each do |tile|
          tile.set_bitmap("", false, false, 0, nil)
          tile.shows_reflection = false
          tile.bridge           = false
        end
      end
    end

    @autotiles.changed = false
  end
end
