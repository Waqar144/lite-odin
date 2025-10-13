package main

import "base:runtime"
import "core:bufio"
import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "core:sys/windows"
_ :: windows

import lua "vendor:lua/5.4"
import sdl "vendor:sdl2"

search_file_find :: proc "c" (L: ^lua.State) -> i32 {

	context = runtime.default_context()
	pattern := string(lua.L_checkstring(L, 1))
	file := string(lua.L_checkstring(L, 2))

	f, ferr := os.open(file)
	if ferr != nil {
		// handle error appropriately
		fmt.println("failed to open ", file)
		return 0
	}
	defer os.close(f)

	r: bufio.Reader
	buffer: [65536]byte
	bufio.reader_init_with_buf(&r, os.stream_from_handle(f), buffer[:])
	defer bufio.reader_destroy(&r)

	pat_u8 := transmute([]u8)(pattern)

	line_no := 1
	num_results: i32 = 0
	for {
		// This will allocate a string because the line might go over the backing
		// buffer and thus need to join things together
		line, err := bufio.reader_read_slice(&r, '\n')

		if err != nil {
			if err == .EOF || err == .Unknown {
				break
			}
			// TODO handle longer lines
		}
		pos := strcasestr(line, pat_u8)
		if pos >= 0 {
			lua.createtable(L, 0, 4)

			lua.pushstring(L, strings.clone_to_cstring(file))
			lua.setfield(L, -2, "file")

			lua.pushstring(L, strings.clone_to_cstring(string(line)))
			lua.setfield(L, -2, "text")

			lua.pushinteger(L, lua.Integer(line_no))
			lua.setfield(L, -2, "line")

			lua.pushinteger(L, lua.Integer(pos + 1))
			lua.setfield(L, -2, "col")
			// fmt.println("Found match at:", line_no, pos + 1, "in:", file)
			num_results += 1
		}

		line_no += 1
	}
	return num_results
}

strcasestr :: proc(h: []u8, n: []u8) -> int {
	lower :: #force_inline proc "contextless" (ch: byte) -> byte {return ('a' - 'A') | ch}
	if len(n) == 0 do return 0

	first := lower(n[0])
	for i := 0; i < len(h); i += 1 {
		if lower(h[i]) == first {
			n_idx := 1
			h_idx := i + 1
			for {
				// needle exhausted, we found the str
				if n_idx >= len(n) do return i
				// haystack exhausted?
				if h_idx >= len(h) do break
				// mismatch, break and try again
				if lower(h[h_idx]) != lower(n[n_idx]) do break
				// move to next char
				n_idx += 1
				h_idx += 1
			}
		}
	}
	return -1
}

button_name :: proc(button: u8) -> cstring {
	switch (button) {
	case 1:
		return "left"
	case 2:
		return "middle"
	case 3:
		return "right"
	case:
		return "?"
	}
}

key_name :: proc(dst: []u8, sym: sdl.Keycode) -> cstring {
	keyname: string = string(sdl.GetKeyName(sym))

	i := 0
	for c in keyname {
		dst[i] = cast(u8)libc.tolower(i32(c))
		i += 1
	}
	return cstring(raw_data(dst))
}

f_poll_event :: proc "c" (L: ^lua.State) -> i32 {
	context = runtime.default_context()
	buf: [16]u8
	mx, my, wx, wy: i32
	e: sdl.Event

	if (!sdl.PollEvent(&e)) {
		return 0
	}

	#partial switch (e.type) {
	case .QUIT:
		lua.pushstring(L, "quit")
		return 1

	case .WINDOWEVENT:
		if (e.window.event == sdl.WindowEventID.RESIZED) {
			lua.pushstring(L, "resized")
			lua.pushinteger(L, lua.Integer(e.window.data1))
			lua.pushinteger(L, lua.Integer(e.window.data2))
			return 3
		} else if (e.window.event == sdl.WindowEventID.EXPOSED) {
			rencache_invalidate()
			lua.pushstring(L, "exposed")
			return 1
		}
		/* on some systems, when alt-tabbing to the window SDL will queue up
         * several KEYDOWN events for the `tab` key; we flush all keydown
         * events on focus so these are discarded */
		if (e.window.event == sdl.WindowEventID.FOCUS_GAINED) {
			sdl.FlushEvent(sdl.EventType.KEYDOWN)
		}
		return f_poll_event(L)

	case .DROPFILE:
		sdl.GetGlobalMouseState(&mx, &my)
		sdl.GetWindowPosition(window, &wx, &wy)
		lua.pushstring(L, "filedropped")
		lua.pushstring(L, e.drop.file)
		lua.pushinteger(L, cast(lua.Integer)(mx - wx))
		lua.pushinteger(L, cast(lua.Integer)(my - wy))
		sdl.free(cast([^]u8)e.drop.file)
		return 4

	case .KEYDOWN:
		lua.pushstring(L, "keypressed")
		lua.pushstring(L, key_name(buf[:], e.key.keysym.sym))
		return 2

	case .KEYUP:
		lua.pushstring(L, "keyreleased")
		lua.pushstring(L, key_name(buf[:], e.key.keysym.sym))
		return 2

	case .TEXTINPUT:
		lua.pushstring(L, "textinput")
		lua.pushstring(L, cstring(raw_data(e.text.text[:])))
		return 2

	case .MOUSEBUTTONDOWN:
		if (e.button.button == 1) {
			sdl.CaptureMouse(true)
		}
		lua.pushstring(L, "mousepressed")
		lua.pushstring(L, button_name(e.button.button))
		lua.pushinteger(L, cast(lua.Integer)e.button.x)
		lua.pushinteger(L, cast(lua.Integer)e.button.y)
		lua.pushinteger(L, cast(lua.Integer)e.button.clicks)
		return 5

	case .MOUSEBUTTONUP:
		if (e.button.button == 1) {
			sdl.CaptureMouse(false)
		}
		lua.pushstring(L, "mousereleased")
		lua.pushstring(L, button_name(e.button.button))
		lua.pushinteger(L, cast(lua.Integer)e.button.x)
		lua.pushinteger(L, cast(lua.Integer)e.button.y)
		return 4

	case .MOUSEMOTION:
		lua.pushstring(L, "mousemoved")
		lua.pushinteger(L, cast(lua.Integer)e.motion.x)
		lua.pushinteger(L, cast(lua.Integer)e.motion.y)
		lua.pushinteger(L, cast(lua.Integer)e.motion.xrel)
		lua.pushinteger(L, cast(lua.Integer)e.motion.yrel)
		return 5

	case .MOUSEWHEEL:
		lua.pushstring(L, "mousewheel")
		lua.pushinteger(L, cast(lua.Integer)e.wheel.y)
		return 2

	case:
		return f_poll_event(L)
	}

	return 0
}

f_wait_event :: proc "c" (L: ^lua.State) -> i32 {
	n: libc.int = cast(libc.int)lua.L_checknumber(L, 1)
	lua.pushboolean(L, cast(b32)sdl.WaitEventTimeout(nil, n * 1000))
	return 1
}

cursor_cache: [sdl.SystemCursor.NUM_SYSTEM_CURSORS]^sdl.Cursor

cursor_opts := []cstring{"arrow", "ibeam", "sizeh", "sizev", "hand"}

cursor_enums := []sdl.SystemCursor {
	sdl.SystemCursor.ARROW,
	sdl.SystemCursor.IBEAM,
	sdl.SystemCursor.SIZEWE,
	sdl.SystemCursor.SIZENS,
	sdl.SystemCursor.HAND,
}

f_set_cursor :: proc "c" (L: ^lua.State) -> i32 {
	opt: i32 = lua.L_checkoption(L, 1, "arrow", raw_data(cursor_opts))
	cursor_value := cursor_enums[opt]
	n: i32 = cast(i32)cursor_value
	cursor: ^sdl.Cursor = cursor_cache[n]
	if (cursor == nil) {
		cursor = sdl.CreateSystemCursor(cursor_value)
		cursor_cache[n] = cursor
	}
	sdl.SetCursor(cursor)
	return 0
}

f_set_window_title :: proc "c" (L: ^lua.State) -> i32 {
	title := lua.L_checkstring(L, 1)
	sdl.SetWindowTitle(window, title)
	return 0
}

window_opts := []cstring{"normal", "maximized", "fullscreen"}
Win :: enum {
	WIN_NORMAL,
	WIN_MAXIMIZED,
	WIN_FULLSCREEN,
}

f_set_window_mode :: proc "c" (L: ^lua.State) -> i32 {
	n := lua.L_checkoption(L, 1, "normal", raw_data(window_opts))
	sdl.SetWindowFullscreen(
		window,
		n == cast(i32)Win.WIN_FULLSCREEN ? sdl.WINDOW_FULLSCREEN_DESKTOP : sdl.WindowFlags{},
	)
	if (n == cast(i32)Win.WIN_NORMAL) {sdl.RestoreWindow(window)}
	if (n == cast(i32)Win.WIN_MAXIMIZED) {sdl.MaximizeWindow(window)}
	return 0
}


f_window_has_focus :: proc "c" (L: ^lua.State) -> i32 {
	flags := sdl.GetWindowFlags(window)
	lua.pushboolean(L, cast(b32)(flags & cast(u32)sdl.WINDOW_INPUT_FOCUS))
	return 1
}

f_show_confirm_dialog :: proc "c" (L: ^lua.State) -> i32 {
	title: cstring = lua.L_checkstring(L, 1)
	msg: cstring = lua.L_checkstring(L, 2)

	when ODIN_OS == .Windows {
		context = runtime.default_context()
		message := windows.utf8_to_wstring(string(msg))
		caption := windows.utf8_to_wstring(string(title))
		id := windows.MessageBoxW(windows.HWND(nil), message, caption, windows.UINT(windows.MB_YESNO | windows.MB_ICONWARNING))
		lua.pushboolean(L, cast(b32)(id == windows.IDYES))
	} else {
		buttons := []sdl.MessageBoxButtonData {
			{sdl.MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT, 1, "Yes"},
			{sdl.MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT, 0, "No"},
		}
		data: sdl.MessageBoxData = {
			title      = title,
			message    = msg,
			numbuttons = 2,
			buttons    = raw_data(buttons),
		}
		buttonid: i32
		sdl.ShowMessageBox(&data, &buttonid)
		lua.pushboolean(L, buttonid == 1)
	}
	return 1
}

f_chdir :: proc "c" (L: ^lua.State) -> i32 {
	context = runtime.default_context()
	path: cstring = lua.L_checkstring(L, 1)
	err := os.set_current_directory(string(path))
	if err != nil {
		lua.L_error(L, "chdir() failed")
	}
	return 0
}

f_list_dir :: proc "c" (L: ^lua.State) -> i32 {
	context = runtime.default_context()
	// create a separate temp region
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	path: cstring = lua.L_checkstring(L, 1)

	handle, err1 := os.open(string(path))
	defer os.close(handle)
	if err1 != nil {
		lua.pushnil(L)
		lua.pushstring(L, strings.unsafe_string_to_cstring(os.error_string(err1)))
		return 2
	}

	entries, err2 := os.read_dir(handle, -1, context.temp_allocator)
	if err2 != nil {
		lua.pushnil(L)
		lua.pushstring(L, strings.unsafe_string_to_cstring(os.error_string(err2)))
		return 2
	}

	lua.newtable(L)
	for e, idx in entries {
		if e.name == "." || e.name == ".." {
			continue
		}
		lua.pushstring(L, cstring(strings.clone_to_cstring(e.name, context.temp_allocator)))
		lua.rawseti(L, -2, cast(lua.Integer)(idx + 1))
	}
	return 1
}

f_absolute_path :: proc "c" (L: ^lua.State) -> i32 {
	context = runtime.default_context()
	path: cstring = lua.L_checkstring(L, 1)
	res, err := filepath.abs(string(path))
	if !err do return 0
	lua.pushstring(L, strings.unsafe_string_to_cstring(res))
	delete(res)
	return 1
}

f_get_file_info :: proc "c" (L: ^lua.State) -> i32 {
	context = runtime.default_context()
	path: cstring = lua.L_checkstring(L, 1)

	fi, err := os.stat(string(path))
	defer os.file_info_delete(fi)
	if err != nil {
		lua.pushnil(L)
		lua.pushstring(L, strings.unsafe_string_to_cstring(os.error_string(err)))
		return 2
	}

	lua.createtable(L, 0, 3)
	lua.pushinteger(L, cast(lua.Integer)time.time_to_unix(fi.modification_time))
	lua.setfield(L, -2, "modified")

	lua.pushinteger(L, cast(lua.Integer)fi.size)
	lua.setfield(L, -2, "size")

	if fi.is_dir {
		lua.pushstring(L, "dir")
	} else {
		lua.pushstring(L, "file")
	}
	lua.setfield(L, -2, "type")
	return 1
}

f_get_clipboard :: proc "c" (L: ^lua.State) -> i32 {
	text: cstring = sdl.GetClipboardText()
	if (text == nil) {return 0}
	lua.pushstring(L, text)
	sdl.free(cast([^]u8)text)
	return 1
}

f_set_clipboard :: proc "c" (L: ^lua.State) -> i32 {
	text: cstring = lua.L_checkstring(L, 1)
	sdl.SetClipboardText(text)
	return 0
}

f_get_time :: proc "c" (L: ^lua.State) -> i32 {
	n := cast(f64)sdl.GetPerformanceCounter() / cast(f64)sdl.GetPerformanceFrequency()
	lua.pushnumber(L, cast(lua.Number)n)
	return 1
}

f_sleep :: proc "c" (L: ^lua.State) -> i32 {
	n := lua.L_checknumber(L, 1)
	sdl.Delay(u32(n * 1000))
	return 0
}

f_exec :: proc "c" (L: ^lua.State) -> i32 {
	context = runtime.default_context()
	len: libc.size_t
	cmd: cstring = lua.L_checkstring(L, 1, &len)
	buf := make([]u8, len + 32)
	defer delete(buf)

	when ODIN_OS == .Windows {
		_ = cmd
		//   sprintf(buf, "cmd /c \"%s\"", cmd);
		//   WinExec(buf, SW_HIDE);
	} else {
		fmt.bprintf(buf, "%s &", cmd)
		fmt.println("sasdasd ", buf)
		_ = libc.system(cast(cstring)raw_data(buf))
	}
	return 0
}

f_fuzzy_match :: proc "c" (L: ^lua.State) -> i32 {
	strng := lua.L_checkstring(L, 1)
	pattern := lua.L_checkstring(L, 2)
	score: i32 = 0
	run: i32 = 0

	str := cast([^]u8)strng
	ptn := cast([^]u8)pattern

	pattern_len := len(pattern)
	str_len := len(strng)

	i, j := 0, 0
	for i < str_len && j < pattern_len {
		for str[i] == ' ' do i += 1
		for ptn[j] == ' ' do j += 1
		if (i >= str_len || j >= pattern_len) do break

		s := str[i]
		p := ptn[j]
		if libc.tolower(i32(s)) == libc.tolower(i32(p)) {
			score += run * 10 - i32(s != p)
			run += 1
			j += 1
		} else {
			score -= 10
			run = 0
		}
		i += 1
	}

	if j < pattern_len {
		return 0
	}

	remaining := str_len - i
	lua.pushinteger(L, cast(lua.Integer)(score - i32(remaining)))

	return 1
}

// odinfmt: disable
@(private="file")
lib := []lua.L_Reg {
  { "poll_event",          f_poll_event          },
  { "wait_event",          f_wait_event          },
  { "set_cursor",          f_set_cursor          },
  { "set_window_title",    f_set_window_title    },
  { "set_window_mode",     f_set_window_mode     },
  { "window_has_focus",    f_window_has_focus    },
  { "show_confirm_dialog", f_show_confirm_dialog },
  { "chdir",               f_chdir               },
  { "list_dir",            f_list_dir            },
  { "absolute_path",       f_absolute_path       },
  { "get_file_info",       f_get_file_info       },
  { "get_clipboard",       f_get_clipboard       },
  { "set_clipboard",       f_set_clipboard       },
  { "get_time",            f_get_time            },
  { "sleep",               f_sleep               },
  { "exec",                f_exec                },
  { "fuzzy_match",         f_fuzzy_match         },
  { "search_file_find",    search_file_find      },
}
// odinfmt: enable

luaopen_system :: proc "c" (L: ^lua.State) -> i32 {
	context = runtime.default_context()
	lua.L_newlib(L, lib)
	return 1
}

