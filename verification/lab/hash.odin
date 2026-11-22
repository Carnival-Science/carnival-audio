// Content hashes for laboratory artifacts.
//
// SHA-256 comes from Odin's standard library; it is not Pulse's DSP and adds no
// shared numerical implementation. Hex output is lowercase, 64 characters.
package verification_lab

import "core:crypto/sha2"

SHA256_BYTES :: 32

sha256_digest :: proc(data: []u8) -> [SHA256_BYTES]u8 {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	if len(data) > 0 {
		sha2.update(&ctx, data)
	}
	digest: [SHA256_BYTES]u8
	sha2.final(&ctx, digest[:])
	return digest
}

sha256_hex :: proc(data: []u8, allocator := context.allocator) -> string {
	digits := "0123456789abcdef"
	digest := sha256_digest(data)
	result := make([]u8, SHA256_BYTES * 2, allocator)
	for byte, index in digest {
		result[index * 2 + 0] = digits[byte >> 4]
		result[index * 2 + 1] = digits[byte & 0x0F]
	}
	return string(result)
}

sha256_hex_string :: proc(text: string, allocator := context.allocator) -> string {
	return sha256_hex(transmute([]u8)text, allocator)
}
