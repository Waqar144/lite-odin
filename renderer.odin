package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"

import sdl "vendor:sdl2"
import stbtt "vendor:stb/truetype"

@(private)
clip: ClipRect

@(private)
MAX_GLYPHSET :: 256

RenColor :: struct {
	b, g, r, a: u8,
}

RenRect :: struct {
	x, y, width, height: i32,
}

RenImage :: struct {
	pixels:        []RenColor,
	width, height: i32,
}

ClipRect :: struct {
	left, top, right, bottom: i32,
}

GlyphSet :: struct {
	image:  ^RenImage,
	glyphs: [256]stbtt.bakedchar,
}

RenFont :: struct {
	data:    []byte,
	stbfont: stbtt.fontinfo,
	sets:    [MAX_GLYPHSET]^GlyphSet,
	size:    f32,
	height:  i32,
}

ren_init :: proc(win: ^sdl.Window) {
	window = win
	surf: ^sdl.Surface = sdl.GetWindowSurface(window)
	ren_set_clip_rect(RenRect{0, 0, surf^.w, surf^.h})
}

initial_frame: bool

@(export)
ren_update_rects :: proc "c" (rects: [^]RenRect, count: i32) {
	sdl.UpdateWindowSurfaceRects(window, transmute([^]sdl.Rect)rects, count)
	initial_frame = true
	if initial_frame {
		sdl.ShowWindow(window)
		initial_frame = false
	}
}

@(export)
ren_set_clip_rect :: proc "c" (rect: RenRect) {
	clip.left = rect.x
	clip.top = rect.y
	clip.right = rect.x + rect.width
	clip.bottom = rect.y + rect.height
}

@(export)
ren_get_size :: proc "c" (x: ^i32, y: ^i32) {
	surf: ^sdl.Surface = sdl.GetWindowSurface(window)
	x^ = surf^.w
	y^ = surf^.h
}

ren_new_image :: proc(width: i32, height: i32) -> ^RenImage {
	assert(width > 0 && height > 0)
	image: ^RenImage = new(RenImage)
	image^.pixels = make([]RenColor, width * height)
	image^.width = width
	image^.height = height
	return image
}

ren_free_image :: proc(image: ^RenImage) {
	delete(image^.pixels)
	free(image)
}

load_glyphset :: proc(font: ^RenFont, idx: i32) -> ^GlyphSet {
	set := new(GlyphSet)
	//
	/* init image */
	width: i32 = 128
	height: i32 = 128


	done: i32 = -1
	for done < 0 {
		//   /* load glyphs */
		set^.image = ren_new_image(width, height)
		s :=
			stbtt.ScaleForMappingEmToPixels(&font.stbfont, 1) /
			stbtt.ScaleForPixelHeight(&font.stbfont, 1)

		res: i32 = stbtt.BakeFontBitmap(
			raw_data(font^.data),
			0,
			font^.size * s,
			transmute([^]u8)raw_data(set^.image^.pixels),
			width,
			height,
			idx * 256,
			256,
			raw_data(&set^.glyphs),
		)

		/* retry with a larger image buffer if the buffer wasn't large enough */
		if (res < 0) {
			width *= 2
			height *= 2
			ren_free_image(set^.image)
			set^.image = ren_new_image(width, height)
		}
		done = res
	}
	/* adjust glyph yoffsets and xadvance */
	ascent, descent, linegap: i32
	stbtt.GetFontVMetrics(&font^.stbfont, &ascent, &descent, &linegap)
	scale: f32 = stbtt.ScaleForMappingEmToPixels(&font^.stbfont, font^.size)
	scaled_ascent: i32 = cast(i32)(f32(ascent) * scale + 0.5)

	for i := 0; i < 256; i += 1 {
		set^.glyphs[i].yoff += f32(scaled_ascent)
		set^.glyphs[i].xadvance = math.floor(set^.glyphs[i].xadvance)
	}

	/* convert 8bit data to 32bit */
	for i := width * height - 1; i >= 0; i -= 1 {
		raw_pixels: [^]RenColor = raw_data(set^.image^.pixels)
		n: u8 = (transmute([^]u8)raw_pixels)[i]
		set^.image^.pixels[i] = RenColor {
			r = 255,
			g = 255,
			b = 255,
			a = n,
		}
	}
	return set
}

get_glyphset :: proc(font: ^RenFont, codepoint: i32) -> ^GlyphSet {
	idx := (codepoint >> 8) % MAX_GLYPHSET
	if font^.sets[idx] == nil {
		font^.sets[idx] = load_glyphset(font, idx)
	}
	return font^.sets[idx]
}

@(export)
ren_load_font :: proc "c" (filename: cstring, size: f32) -> ^RenFont {
	context = runtime.default_context()
	/* init font */
	font := new(RenFont)
	font^.size = size

	/* load font into buffer */
	data, success := os.read_entire_file_from_filename(string(filename))
	if !success {
		fmt.println("Failed to read file from filename", filename)
		free(font)
		return nil
	}
	font^.data = data

	/* init stbfont */
	ok := cast(i32)stbtt.InitFont(&font^.stbfont, raw_data(font^.data), 0)
	if ok == 0 {
		fmt.println("Failed to init font")
		return nil
	}

	/* get height and scale */
	ascent, descent, linegap: i32
	stbtt.GetFontVMetrics(&font^.stbfont, &ascent, &descent, &linegap)
	scale := stbtt.ScaleForMappingEmToPixels(&font^.stbfont, size)
	font^.height = cast(i32)(cast(f32)(ascent - descent + linegap) * scale + 0.5)

	/* make tab and newline glyphs invisible */
	set: ^GlyphSet = get_glyphset(font, '\n')
	set^.glyphs['\t'].x1 = set^.glyphs['\t'].x0
	set^.glyphs['\n'].x1 = set^.glyphs['\n'].x0

	return font
}

@(export)
ren_free_font :: proc "c" (font: ^RenFont) {
	context = runtime.default_context()
	for i := 0; i < MAX_GLYPHSET; i += 1 {
		set: ^GlyphSet = font^.sets[i]
		if set != nil {
			ren_free_image(set^.image)
			free(set)
		}
	}
	delete(font^.data)
	free(font)
}

@(export)
ren_set_font_tab_width :: proc "c" (font: ^RenFont, n: i32) {
	context = runtime.default_context()
	set: ^GlyphSet = get_glyphset(font, '\t')
	set^.glyphs['\t'].xadvance = cast(f32)n
}


@(export)
ren_get_font_tab_width :: proc "c" (font: ^RenFont) -> i32 {
	context = runtime.default_context()
	set: ^GlyphSet = get_glyphset(font, '\t')
	return cast(i32)set^.glyphs['\t'].xadvance
}

@(export)
ren_get_font_width :: proc "c" (font: ^RenFont, text: cstring) -> i32 {
	context = runtime.default_context()
	x: i32 = 0
	p := string(text) // not a copy
	for codepoint, index in p {
		set: ^GlyphSet = get_glyphset(font, cast(i32)codepoint)
		g: ^stbtt.bakedchar = &set^.glyphs[codepoint & 0xff]
		x += cast(i32)g^.xadvance
	}
	return x
}

@(export)
ren_get_font_height :: proc "c" (font: ^RenFont) -> i32 {
	return font^.height
}

blend_pixel :: proc(dst: RenColor, src: RenColor) -> RenColor {
	dst := dst

	ia := u32(0xff - src.a)
	src_a := u32(src.a)
	dst.r = u8(((u32(src.r) * src_a) + (u32(dst.r) * ia)) >> 8)
	dst.g = u8(((u32(src.g) * src_a) + (u32(dst.g) * ia)) >> 8)
	dst.b = u8(((u32(src.b) * src_a) + (u32(dst.b) * ia)) >> 8)
	return dst
}

blend_pixel2 :: proc(dst: RenColor, src: RenColor, color: RenColor) -> RenColor {
	dst := dst

	src_a := (u32(src.a) * u32(color.a)) >> 8
	ia: u32 = u32(0xff - src.a)
	dst.r = u8((u32(src.r) * u32(color.r) * src_a >> 16) + ((u32(dst.r) * ia) >> 8))
	dst.g = u8((u32(src.g) * u32(color.g) * src_a >> 16) + ((u32(dst.g) * ia) >> 8))
	dst.b = u8((u32(src.b) * u32(color.b) * src_a >> 16) + ((u32(dst.b) * ia) >> 8))

	return dst
}

@(export)
ren_draw_rect :: proc "c" (rect: RenRect, color: RenColor) {
	if (color.a == 0) {
		return
	}

	context = runtime.default_context()

	x1: i32 = rect.x < clip.left ? clip.left : rect.x
	y1: i32 = rect.y < clip.top ? clip.top : rect.y
	x2: i32 = rect.x + rect.width
	y2: i32 = rect.y + rect.height
	x2 = x2 > clip.right ? clip.right : x2
	y2 = y2 > clip.bottom ? clip.bottom : y2

	surf: ^sdl.Surface = sdl.GetWindowSurface(window)
	d: ^RenColor = transmute(^RenColor)surf^.pixels
	d = mem.ptr_offset(d, x1 + y1 * surf^.w)
	dr := surf^.w - (x2 - x1)

	if color.a == 0xff {
		for j := y1; j < y2; j += 1 {
			for i := x1; i < x2; i += 1 {
				d^ = color
				d = mem.ptr_offset(d, 1)
			}
			d = mem.ptr_offset(d, dr)
		}
	} else {
		for j := y1; j < y2; j += 1 {
			for i := x1; i < x2; i += 1 {
				d^ = blend_pixel(d^, color)
				d = mem.ptr_offset(d, 1)
			}
			d = mem.ptr_offset(d, dr)
		}
	}
}

@(export)
ren_draw_image :: proc "c" (image: ^RenImage, sub: ^RenRect, x: i32, y: i32, color: RenColor) {
	context = runtime.default_context()
	if color.a == 0 {
		return
	}
	x := x
	y := y

	/* clip */
	n := clip.left - x
	if n > 0 {
		sub^.width -= n
		sub^.x += n
		x += n
	}

	n = clip.top - y
	if n > 0 {
		sub^.height -= n
		sub^.y += n
		y += n
	}

	n = x + sub^.width - clip.right
	if n > 0 {
		sub^.width -= n
	}

	n = y + sub^.height - clip.bottom
	if n > 0 {
		sub^.height -= n
	}

	if (sub^.width <= 0 || sub^.height <= 0) {
		return
	}

	/* draw */
	surf: ^sdl.Surface = sdl.GetWindowSurface(window)
	s: [^]RenColor = transmute([^]RenColor)raw_data(image^.pixels)
	d: [^]RenColor = transmute([^]RenColor)(surf^.pixels)
	s = mem.ptr_offset(s, sub^.x + sub^.y * image^.width)
	d = mem.ptr_offset(d, x + y * surf^.w)
	sr := image^.width - sub^.width
	dr := surf^.w - sub^.width

	for j := 0; j < cast(int)sub^.height; j += 1 {
		for i := 0; i < cast(int)sub^.width; i += 1 {
			d[0] = blend_pixel2(d[0], s[0], color)
			d = mem.ptr_offset(d, 1)
			s = mem.ptr_offset(s, 1)
		}
		d = mem.ptr_offset(d, dr)
		s = mem.ptr_offset(s, sr)
	}
}

@(export)
ren_draw_text :: proc "c" (font: ^RenFont, text: cstring, x: int, y: int, color: RenColor) -> int {
	context = runtime.default_context()
	rect: RenRect
	x := x
	p := string(text) // not a copy

	for codepoint, index in p {
		set: ^GlyphSet = get_glyphset(font, cast(i32)codepoint)
		g: ^stbtt.bakedchar = &set^.glyphs[codepoint & 0xff]

		rect.x = cast(i32)g^.x0
		rect.y = cast(i32)g^.y0
		rect.width = cast(i32)(g^.x1 - g^.x0)
		rect.height = cast(i32)(g^.y1 - g^.y0)
		ren_draw_image(
			set^.image,
			&rect,
			cast(i32)(cast(f32)x + g^.xoff),
			cast(i32)(cast(f32)y + g^.yoff),
			color,
		)
		x += cast(int)g^.xadvance
	}
	return x
}

