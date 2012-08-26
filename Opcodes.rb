$opcodes = {}
$subopcodes = {}
def opcode(opcd, mnem, size, format=nil)
	if opcd.is_a? Array
		opcd, sub = opcd
	else
		sub = nil
	end
	
	case size
		when :bw
			makeOpcode opcd, sub, mnem, :byte, format
			makeOpcode opcd|0x8, sub, mnem, :word, format
		else
			makeOpcode opcd, sub, mnem, size, format
	end
end

def ensureSub(opcd, sub)
	return if $opcodes.has_key? opcd
	
	if sub.is_a? Fixnum
		$opcodes[opcd] = lambda do
			sub = peekuint8 & 0xF
			if $subopcodes.has_key? [opcd, sub]
				instance_eval &($subopcodes[[opcd, sub]])
			else
				raise 'Unknown sub for 0x%02X: %X at 0x%08X' % [opcd, sub, @pc]
			end
		end
	else
		$opcodes[opcd] = lambda do
			sub = (peekuint8 & 0x80) == 0x80
			if $subopcodes.has_key? [opcd, sub]
				instance_eval &($subopcodes[[opcd, sub]])
			else
				raise 'Unknown sub for 0x%02X: %s at 0x%08X' % [opcd, sub, @pc]
			end
		end
	end
end

def makeOpcode(opcd, sub, mnem, size, format)
	handler = lambda do
			ops = parse format, size
			
			if $instructions.has_key? mnem
				$instructions[mnem].call *ops
			else
				raise 'No instruction handler for %s' % mnem
			end
		end
	if sub == nil
		$opcodes[opcd] = handler
	else
		ensureSub opcd, sub
		$subopcodes[[opcd, sub]] = handler
	end
end

$instructions = {}
def instruction(mnem, &block)
	$instructions[mnem] = block
end

opcode [0x86, true], :mov, :bw, 'direct,R'
opcode [0x91, 0x8], :mov, :bw, 'R,#data'
opcode [0x96, 0x8], :mov, :bw, 'direct,#data'
opcode 0xB1, :mov, :bw, 'R,#data4'
instruction :mov do |dest, src|
	dest.value = src
end

opcode 0xB6, :movs, :bw, 'direct,#data4'
instruction :movs do |dest, src|
	dest.value = src
end








$nopcodes = {}

def nopcode(opcd, &block)
	$nopcodes[opcd] = block
end

# nop
nopcode 0x00

# add.w Rd, Rs
nopcode 0x09 do
	a = uint8
	dest, src = a >> 4, a & 0xF
	
	reg.word[dest] += reg.word[src]
end

# setb
nopcode 0x08 do
	addr = ((uint8 & 3) << 8) | uint8
	
	if addr < 0x100 # Register
		word, offset = addr >> 4, addr & 0xF
		reg.word[word] |= 1 << offset
	elsif addr < 0x200 # Memory
		byte, offset = addr >> 5, addr & 0x7
		mem.byte[byte] |= 1 << offset
	elsif addr < 0x400 # SFR
		byte, offset = addr >> 5, addr & 0x7
		sfr.byte[byte] |= 1 << offset
	end
end

# push.w Rlist
nopcode 0x0F do
	map = uint8
	(0...8).each do |i|
		if map & (1 << i) != 0
			push reg.word[i], 16
		end
	end
end

# sub.w Rd, Rs
nopcode 0x29 do
	a = uint8
	dest, src = a >> 4, a & 0xF
	
	value = reg.word[dest] - reg.word[src]
	value += 0x10000 if value < 0
	reg.word[dest] = value
end

# pop.w Rlist
nopcode 0x2F do
	map = uint8
	(0...8).each do |i|
		i = 7 - i
		if map & (1 << i) != 0
			reg.word[i] = pop 16
		end
	end
end

# subb.w Rd, Rs
nopcode 0x39 do
	a = uint8
	dest, src = a >> 4, a & 0xF
	
	value = reg.word[dest] - reg.word[src] - cf
	value += 0x10000 if value < 0
	reg.word[dest] = value
end

# cmp.w Rd, Rs
nopcode 0x49 do
	a = uint8
	dest, src = reg.word[a >> 4], reg.word[a & 0xF]
	
	if src > dest then nf 1; cf 1; vf 1
	else nf 0; cf 0; vf 0
	end
	if src == dest then zf 1
	else zf 0
	end
end

# and.b Rd, [Rs+offset8]
# and.b [Rd+offset8], Rs
nopcode 0x54 do
	a, offset = uint8, uint8
	
	if a & 8 == 8 # [Rd+offset8], Rs
		src, dest = a >> 4, a & 0x7
		mem.byte[reg.word[dest] + offset] &= reg.byte[src]
	else # Rd, [Rs+offset8]
		dest, src = a >> 4, a & 0x7
		reg.byte[dest] &= mem.byte[reg.word[src] + offset]
	end
end

# or.b Rd, [Rs]
# or.b [Rd], Rs
nopcode 0x62 do
	a = uint8
	
	if a & 8 == 8 # [Rd], Rs
		src, dest = a >> 4, a & 0x7
		mem.byte[reg.word[dest]] |= reg.byte[src]
	else # Rd, [Rs]
		dest, src = a >> 4, a & 0x7
		reg.byte[dest] |= mem.byte[reg.word[src]]
	end
end

# or.b Rd, [Rs+offset8]
# or.b [Rd+offset8], Rs
nopcode 0x64 do
	a, offset = uint8, uint8
	
	if a & 8 == 8 # [Rd+offset8], Rs
		src, dest = a >> 4, a & 0x7
		mem.byte[reg.word[dest]+offset] |= reg.byte[src]
	else # Rd, [Rs+offset8]
		dest, src = a >> 4, a & 0x7
		reg.byte[dest] |= mem.byte[reg.word[src] + offset]
	end
end

# movc.b Rd, [Rs+]
nopcode 0x80 do
	a = uint8
	
	dest, src = a >> 4, a & 0x7
	reg.byte[dest] = codemem.byte[reg.word[src]]
	reg.word[src] += 1
end

# mov.b Rd, Rs
nopcode 0x81 do
	a = uint8
	
	dest, src = a >> 4, a & 0xF
	reg.byte[dest] = reg.byte[src]
end

# mov.b Rd, [Rs]
# mov.b [Rd], Rs
nopcode 0x82 do
	a = uint8
	
	if a & 8 == 8 # [Rd], Rs
		src, dest = a >> 4, a & 7
		mem.byte[reg.word[dest]] = reg.byte[src]
	else # Rd, [Rs]
		src, dest = a & 7, a >> 4
		reg.byte[dest] = mem.byte[reg.word[src]]
	end
end

# mov.b Rd, [Rs+]
# mov.b [Rd+], Rs
nopcode 0x83 do
	a = uint8
	
	if a & 8 == 8 # [Rd+], Rs
		src, dest = a >> 4, a & 7
		mem.byte[reg.word[dest]] = reg.byte[src]
		reg.word[dest] += 1
	else # Rd, [Rs+]
		dest, src = a >> 4, a & 7
		reg.byte[dest] = mem.byte[reg.word[src]]
		reg.word[src] += 1
	end
end

# mov.b Rd, [Rs+offset8]
# mov.b [Rd+offset8], Rs
nopcode 0x84 do
	a, offset = uint8, uint8.to_sint8
	
	if a & 8 == 8 # [Rd+offset8], Rs
		src, dest = a >> 4, a & 7
		mem.byte[reg.word[dest]+offset] = reg.byte[src]
	else # Rd, [Rs+offset8]
		dest, src = a >> 4, a & 7
		reg.byte[dest] = mem.byte[reg.word[src]+offset]
	end
end

# mov.b direct, Rs
nopcode 0x86 do
	a, b = uint8, uint8
	direct, src = ((a & 7) << 8) | b, a >> 4
	
	mem.byte[direct] = reg.byte[src]
end

# mov.w Rd, Rs
nopcode 0x89 do
	a = uint8
	
	dest, src = a >> 4, a & 0xF
	reg.word[dest] = reg.word[src]
end

# mov.w Rd, [Rs]
# mov.w [Rd], Rs
nopcode 0x8A do
	a = uint8
	
	if a & 8 == 8 # [Rd], Rs
		src, dest = a >> 4, a & 7
		mem.word[reg.word[dest]] = reg.word[src]
	else # Rd, [Rs]
		src, dest = a & 7, a >> 4
		reg.word[dest] = mem.word[reg.word[src]]
	end
end

# mov.w Rd, [Rs+offset8]
# mov.w [Rd+offset8], Rs
nopcode 0x8C do
	a, offset = uint8, uint8.to_sint8
	
	if a & 8 == 8 # [Rd+offset8], Rs
		src, dest = a >> 4, a & 7
		mem.word[reg.word[dest]+offset] = reg.word[src]
	else # Rd, [Rs+offset8]
		dest, src = a >> 4, a & 7
		reg.word[dest] = mem.word[reg.word[src]+offset]
	end
end

# djnz.w Rd, rel8
nopcode 0x8F do
	a = uint8
	
	case a & 0xF
		when 8 # djnz.w
			rel = uint8.to_sint8
			dest = a >> 4
			reg.word[dest] -= 1
			value = reg.word[dest]
			if value == 0 then zf 1; nf 0
			elsif value < 0 then zf 0; nf 1
			else zf 0; nf 0
			end
			if zf == 0
				@pc -= 1 if @pc & 1 != 0
				branch @pc + rel * 2
			end
		else
			raise 'Unknown 0x8F bits: %X at %08X' % [a & 0xF, @pc]
	end
end

# cpl.b Rd
nopcode 0x90 do
	a = uint8
	
	case a & 0xF
		when 0xA # cpl.b
			dest = a >> 4
			reg.byte[dest] ^= 0xFF
		else
			raise 'Unknown 0x90 bits: %X at %08X' % [a & 0xF, @pc]
	end
end

# cmp.b Rd, #data8
nopcode 0x91 do
	a = uint8
	dest, data = a >> 4, uint8
	
	case a & 0xF
		when 4 # cmp.b
			value = reg.byte[dest]
			if data > value then nf 1; cf 1; vf 1
			else nf 0; cf 0; vf 0
			end
			if data == value then zf 1
			else zf 0
			end
		else
			raise 'Unknown 0x91 bits: %X at %08X' % [a & 0xF, @pc]
	end
end

# and.b [Rd], #data8
# or.b [Rd], #data8
# mov.b [Rd], #data8
nopcode 0x92 do
	a, data = uint8, uint8
	
	case a & 0xF
		when 0x5 # and.b [Rd], #data8
			mem.byte[reg.word[a >> 4]] &= data
		when 0x6 # or.b [Rd], #data8
			mem.byte[reg.word[a >> 4]] |= data
		when 0x8 # mov.b [Rd], #data8
			mem.byte[reg.word[a >> 4]] = data
		else
			raise 'Unknown 0x92 bits: %X at %08X' % [a & 0xF, @pc]
	end
end

# cmp.b [Rd+offset8], #data8
nopcode 0x94 do
	a = uint8
	offset, data = uint8.to_sint8, uint8
	
	case a & 0xF
		when 4 # cmp.b
			dest, src = mem.byte[reg.word[a >> 4] + offset], data
			
			if src > dest then nf 1; cf 1; vf 1
			else nf 0; cf 0; vf 0
			end
			if src == dest then zf 1
			else zf 0
			end
		else
			raise 'Unknown 0x94 bits: %X at %08X' % [a & 0xF, @pc]
	end
end

# mov.b direct, #data8
# and.b direct, #data8
nopcode 0x96 do
	a, b, data = uint8, uint8, uint8
	direct = ((a & 0x70) << 4) | b
	
	case a & 0xF
		when 8 # mov.b
			if direct < 0x400
				mem.byte[direct] = data
			else
				sfr.byte[direct] = data
			end
		when 5 # and.b
			if direct < 0x400
				mem.byte[direct] &= data
			else
				sfr.byte[direct] &= data
			end
		else
			raise 'Unknown 0x96 bits: %X at %08X' % [a & 0xF, @pc]
	end
end

# sext.w Rd
nopcode 0x98 do
	a = uint8
	
	case a & 0xF
		when 9 # sext.w
			reg.word[a >> 4] = 
				if nf then 0xFFFF
				else 0
				end
		else
			raise 'Unknown 0x98 bits: %X at %08X' % [a & 0xF, @pc]
	end
end

# add.w Rd, #data16
# addc.w Rd, #data16
# mov.w Rd, #data16
# cmp.w Rd, #data16
# mov.w Rd, #data16
nopcode 0x99 do
	a = uint8
	dest, addr = a >> 4, (uint8 << 8) | uint8
	
	case a & 0xF
		when 0 # add.w
			reg.word[dest] += addr
		when 1 # addc.w
			reg.word[dest] += addr + cf
		when 2 # mov.w
			reg.word[dest] = addr
		when 4 # cmp.w
			value = reg.word[dest]
			if addr > value then nf 1; cf 1; vf 1
			else nf 0; cf 0; vf 0
			end
			if addr == value then zf 1
			else zf 0
			end
		when 8 # mov.w
			reg.word[dest] = addr
		else
			raise 'Unknown 0x99 bits: %X at %08X' % [a & 0xF, @pc]
	end
end

# sub.w [Rd], #data16
# cmp.w [Rd], #data16
# and.w [Rd], #data16
# or.w [Rd], #data16
# mov.w [Rd], #data16
nopcode 0x9A do
	a, data = uint8, (uint8 << 8) | uint8
	
	case a & 0xF
		when 0x2 # sub.w
			mem.word[reg.word[a >> 4]] -= data
		when 0x4 # cmp.w
			value = reg.word[a >> 4]
			if data > value then nf 1; cf 1; vf 1
			else nf 0; cf 0; vf 0
			end
			if data == value then zf 1
			else zf 0
			end
		when 0x5 # and.w
			mem.word[reg.word[a >> 4]] &= data
		when 0x6 # or.w
			mem.word[reg.word[a >> 4]] |= data
		when 0x8 # mov.w
			mem.word[reg.word[a >> 4]] = data
		else
			raise 'Unknown 0x9A bits: %X at %08X' % [a & 0xF, @pc]
	end
end

# sub.w [Rd+offset8], #data8
# subb.w [Rd+offset8], #data8
# cmp.w [Rd+offset8], #data8
nopcode 0x9C do
	a = uint8
	offset, data = uint8.to_sint8, (uint8 << 8) | uint8
	
	case a & 0xF
		when 2 # sub.w
			mem.word[reg.word[a >> 4]] -= data
		when 3 # subb.w
			mem.word[reg.word[a >> 4]] -= data + cf
		when 4 # cmp.w
			value = mem.word[reg.word[a >> 4]]
			if data > value then nf 1; cf 1; vf 1
			else nf 0; cf 0; vf 0
			end
			if data == value then zf 1
			else zf 0
			end
		else
			raise 'Unknown 0x9C bits: %X at %08X' % [a & 0xF, @pc]
	end
end

# adds.w Rd, #data4
nopcode 0xA9 do
	a = uint8
	dest, data = a >> 4, a & 0xF
	reg.word[dest] += data.to_sint4
end

# adds.w [Rd], #data4
nopcode 0xAA do
	a = uint8
	dest, data = a >> 4, a & 0xF
	mem.word[reg.word[dest]] += data.to_sint4
end

# adds.w [Rd+offset8], #data4
nopcode 0xAC do
	a, offset = uint8, uint8
	dest, data = a >> 4, a & 0xF
	mem.word[reg.word[dest] + offset] += data.to_sint4
end

# movs.b Rd, #data4
nopcode 0xB1 do
	a = uint8
	dest, data = a >> 4, a & 0xF
	
	reg.byte[dest] = data
end

# movs.w Rd, #data4
nopcode 0xB9 do
	a = uint8
	dest, data = a >> 4, a & 0xF
	
	reg.word[dest] = data
end

# movs.b [Rd], #data4
nopcode 0xB2 do
	a = uint8
	dest, data = a >> 4, a & 0xF
	
	mem.byte[reg.word[dest]] = data
end

# movs.b [Rd+], #data4
nopcode 0xB3 do
	a = uint8
	dest, data = a >> 4, a & 0xF
	
	mem.byte[reg.word[dest]] = data
	reg.word[dest] += 1
end

# movs.b direct, #data4
nopcode 0xB6 do
	a, b = uint8, uint8
	direct = ((a & 0x0E) << 7) | b
	data = a >> 4
	
	if direct < 0x400
		mem.byte[direct] = data
	else
		sfr.byte[direct] = data
	end
end

# movs.w [Rd], #data4
nopcode 0xBA do
	a = uint8
	dest, data = a >> 4, a & 0xF
	
	mem.word[reg.word[dest]] = data
end

# asl.b Rd, Rs
nopcode 0xC1 do
	a = uint8
	
	dest, src = a >> 4, a & 0xF
	reg.byte[dest] <<= reg.byte[src]
end

# fcall addr24
nopcode 0xC4 do
	addr = (uint8 << 8) | uint8 | (uint8 << 16)
	
	push @pc, 24
	branch addr, :call
end

# call rel16
nopcode 0xC5 do
	rel = (uint8 << 8) | uint8
	
	push @pc, 24
	@pc -= 1 if @pc & 1 != 0
	branch @pc + rel.to_sint16 * 2, :call
end

# jmp rel16
nopcode 0xD5 do
	rel = (uint8 << 8) | uint8
	
	@pc -= 1 if @pc & 1 != 0
	branch @pc + rel.to_sint16 * 2
end

# ret
nopcode 0xD6 do
	a = uint8
	
	case a
		when 0x80 # ret
			branch pop(24), :return
		else
			raise 'Unknown 0xD6 bits: %X at %08X' % [a, @pc]
	end
end

# lsr.d Rd, #data5
nopcode 0xDC do
	a = uint8
	d, data = a >> 5, a & 0x1F
	
	reg.dword[d] >>= data
end

# mulu.w Rd, Rs
nopcode 0xE4 do
	a = uint8
	dest, src = a >> 4, a & 0xF
	
	value = reg.word[dest] * reg.word[src]
	
	reg.word[dest] = value & 0xFFFF
	reg.word[dest + 1] = value >> 16
end

# div.d Rd, #data16
nopcode 0xE9 do
	a, data = uint8, (uint8 << 8) | uint8
	dest = a >> 4
	
	case a & 0xF
		when 9 # div.d
			rval = reg.word[dest]
			div, mod = rval / data, rval % data
			reg.word[dest] = div
			reg.word[dest + 1] = mod
		else
			raise 'Unknown 0xE9 bits: %X at %08X' % [a & 0xF, @pc]
	end
end

# bne rel16
nopcode 0xF2 do
	rel = uint8.to_sint8
	
	if zf == 0
		@pc -= 1 if @pc & 1 != 0
		branch @pc + rel * 2
	end
end

# beq rel16
nopcode 0xF3 do
	rel = uint8.to_sint8
	
	if zf == 1
		@pc -= 1 if @pc & 1 != 0
		branch @pc + rel * 2
	end
end

# bg rel16
nopcode 0xF8 do
	rel = uint8.to_sint8
	
	if cf == 1
		@pc -= 1 if @pc & 1 != 0
		branch @pc + rel * 2
	end
end

# bl rel16
nopcode 0xF9 do
	rel = uint8.to_sint8
	
	if zf == 1 or cf == 1
		@pc -= 1 if @pc & 1 != 0
		branch @pc + rel * 2
	end
end

# bge rel16
nopcode 0xFA do
	rel = uint8.to_sint8
	
	if nf ^ vf == 0
		@pc -= 1 if @pc & 1 != 0
		branch @pc + rel * 2
	end
end

# bgt rel16
nopcode 0xFC do
	rel = uint8.to_sint8
	
	if (zf | nf) ^ vf == 0
		@pc -= 1 if @pc & 1 != 0
		branch @pc + rel * 2
	end
end

# br rel8
nopcode 0xFE do
	rel = uint8.to_sint8
	@pc -= 1 if @pc & 1 != 0
	branch @pc + rel * 2
end
