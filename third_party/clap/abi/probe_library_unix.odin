#+build !windows
package clap

import "core:strings"
import posix "core:sys/posix"

// Minimal dynamic-library handle used only by the ABI calling-convention test.
Library :: struct {
	handle: rawptr,
}

load_library :: proc(path: string) -> (Library, bool) {
	handle := posix.dlopen(strings.clone_to_cstring(path, context.temp_allocator), posix.RTLD_Flags{.NOW})
	if handle == nil {
		return {}, false
	}
	return Library{handle = rawptr(handle)}, true
}

library_symbol :: proc(library: Library, name: cstring) -> rawptr {
	return posix.dlsym(posix.Symbol_Table(library.handle), name)
}

close_library :: proc(library: Library) {
	_ = posix.dlclose(posix.Symbol_Table(library.handle))
}
