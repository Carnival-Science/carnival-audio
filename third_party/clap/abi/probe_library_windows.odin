#+build windows
package clap

import win "core:sys/windows"

// Minimal dynamic-library handle used only by the ABI calling-convention test.
Library :: struct {
	handle: rawptr,
}

load_library :: proc(path: string) -> (Library, bool) {
	wide := win.utf8_to_utf16_alloc(path, context.temp_allocator)
	handle := win.LoadLibraryW(win.LPCWSTR(raw_data(wide)))
	if handle == nil {
		return {}, false
	}
	return Library{handle = rawptr(handle)}, true
}

library_symbol :: proc(library: Library, name: cstring) -> rawptr {
	return win.GetProcAddress(win.HMODULE(library.handle), win.LPCSTR(name))
}

close_library :: proc(library: Library) {
	_ = win.FreeLibrary(win.HMODULE(library.handle))
}
