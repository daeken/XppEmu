require 'pp'
require 'Opcodes'

class Fixnum
	def to_sint8
		if self & 0x80 != 0
			self - 0x100
		else
			self
		end
	end
	
	def to_sint16
		if self & 0x8000 != 0
			self - 0x10000
		else
			self
		end
	end
	
	def to_sint4
		if self & 0x8 != 0
			self - 0x10
		else
			self
		end
	end
end

class Ref
	def initialize(base, size, addr)
		@base = base
		@size = size
		@addr = addr
	end
	
	def value
		@base.as @size
		@base[@addr]
	end
	
	def value=(val)
		@base.as @size
		@base[@addr] = val
	end
end

class AddrBase
	def cpuSet(cpu_)
		@cpu = cpu_
		self
	end
	
	def as(type) @as = type end
	
	def cpu
		@cpu
	end
	
	def byte
		@as = :byte
		self
	end
	
	def word
		@as = :word
		self
	end
	
	def dword
		@as = :dword
		self
	end
	
	def pc
		@as = :pc
		self
	end
	
	def ref(size, reg)
		Ref.new self, size, reg
	end
end

class Registers < AddrBase
	def initialize
		@gp = [0] * 20 # 4 copies of R0-R3, R4-R7
		
		@bank = 0
	end
	
	def map(reg)
		if reg < 4
			reg + @bank * 4
		elsif reg < 8
			reg + 12
		else
			0
		end
	end
	
	def [](reg)
		reg = map reg
		
		value = 
			case @as
				when :byte
					@gp[reg] & 0xFF
				
				when :word
					@gp[reg]
				
				when :dword
					(@gp[reg+1] << 16) | @gp[reg]
			end
		
		if @cpu.traceregs.include? reg
			puts 'Register trace for R%i triggered at 0x%08X: Read %X (%s)' % [reg, @cpu.pc, value, @as]
		end
		
		value
	end
	
	def []=(reg, value)
		if @cpu.traceregs.include? reg
			puts 'Register trace for R%i triggered at 0x%08X: Writing %X (%s)' % [reg, @cpu.pc, value, @as]
		end
		
		reg = map reg
		
		case @as
			when :byte
				@gp[reg] = (@gp[reg] & 0xFF00) | value
			
			when :word
				@gp[reg] = value & 0xFFFF
			
			when :dword
				@gp[reg] = value & 0xFFFF
				@gp[reg+1] = (value >> 16) & 0xFFFF
		end
	end
end

class SFRs < AddrBase
	def [](reg)
		puts 'SFR read: 0x%X' % reg
		0
	end
	
	def []=(reg, value)
		puts 'SFR write: 0x%X = %X' % [reg, value]
	end
end

class Memory < AddrBase
	def initialize
		@map = []
		
		addMemory 0, 2*1024*1024 # 2MB
	end
	
	def addMemory(addr, size)
		@map[@map.size] = [addr, "\0" * size]
	end
	
	def map(addr)
		for base, bank in @map
			if addr >= base and addr < base + bank.size
				return [addr - base, bank]
			end
		end
		
		nil
	end
	
	def trace(addr, value, type)
		size = 
			case @as
				when :byte then 1
				when :word then 2
				when :pc then 3
			end
		
		for sub in addr...addr+size
			if @cpu.tracemems.include? sub
				if sub != addr
					off = ' (-%i)' % (sub-addr)
				else
					off = ''
				end
				
				puts 'Memory trace for 0x%08X%s triggered at 0x%08X: %s 0x%X (%s)' % [sub, off, @cpu.pc, type, value, @as]
			end
		end
	end
	
	def [](addr)
		offset, bank = map addr
		value = 
			case @as
				when :byte
					bank[offset].ord
				when :word
					bank[offset...offset+2].unpack('v')[0]
				when :pc
					(bank[offset].ord << 16) | (bank[offset+1...offset+3].unpack('v')[0])
			end
		
		trace addr, value, :Read
		
		value
	end
	
	def []=(addr, value)
		trace addr, value, :Write
		
		offset, bank = map addr
		case @as
			when :byte
				bank[offset] = value.chr
			when :word
				bank[offset...offset+2] = [value].pack 'v'
			when :pc
				bank[offset] = (value >> 16).chr
				bank[offset+1...offset+3] = [value].pack 'v'
		end
	end
end

class CodeMemory < AddrBase
	def [](addr)
		case @as
			when :byte
				@cpu.firmware[addr].ord
			when :word
				@cpu.firmware[addr...addr+2].unpack('v')[0]
		end
	end
end

class Cpu
	def initialize(firmware)
		@firmware = firmware
		
		@interrupts = (0...71).map do |i|
			i <<= 2
			@firmware[i...i+4].unpack 'vv'
		end
		
		@pc = @interrupts[0][1]
		@registers = Registers.new.cpuSet self
		@sfrs = SFRs.new.cpuSet self
		@memory = Memory.new.cpuSet self
		@codememory = CodeMemory.new.cpuSet self
		
		@funcs = []
		@blocks = []
		
		@breakpoints = []
		@traceregs = []
		@tracemems = []
		
		@verbose = false
		
		@psw = 0
	end
	
	def toggle_verbose()
		@verbose = !@verbose
		@verbose
	end
	
	def tracereg(r)
		if @traceregs.include? r
			@traceregs.delete r
			false
		else
			@traceregs[@traceregs.size] = r
			true
		end
	end
	
	def tracemem(addr)
		if @tracemems.include? addr
			@tracemems.delete addr
			false
		else
			@tracemems[@tracemems.size] = addr
			true
		end
	end
	
	def traceregs() @traceregs end
	def tracemems() @tracemems end
	
	def breakpoints() @breakpoints end
	def funcs() @funcs end
	def blocks() @blocks end
	
	def pc() @pc end
	def firmware() @firmware end
	def reg() @registers end
	def sfr() @sfrs end
	def mem() @memory end
	def codemem() @codememory end
	
	def add_bp(addr)
		if @breakpoints.include? addr
			@breakpoints.delete addr
			false
		else
			@breakpoints[@breakpoints.size] = addr
			true
		end
	end
	
	def psw(value=nil)
		@psw = value if value != nil
		@psw
	end
	
	def cf(value=nil)
		if value != nil
			@psw &= 0xFF7F
			@psw |= value << 7
		end
		(@psw & 0x80) >> 7
	end
	
	def acf(value=nil)
		if value != nil
			@psw &= 0xFFBF
			@psw |= value << 6
		end
		(@psw & 0x40) >> 6
	end
	
	def vf(value=nil)
		if value != nil
			@psw &= 0xFFFB
			@psw |= value << 2
		end
		(@psw & 0x04) >> 2
	end
	
	def nf(value=nil)
		if value != nil
			@psw &= 0xFFFD
			@psw |= value << 1
		end
		(@psw & 0x02) >> 1
	end
	
	def zf(value=nil)
		if value != nil
			@psw &= 0xFFFE
			@psw |= value
		end
		@psw & 1
	end
	
	def peekuint8
		if @firmware.size > @pc
			@firmware[@pc].ord
		else
			raise "PC out of bounds: %08x" % @pc
		end
	end
	
	def uint8
		value = peekuint8
		@pc += 1
		return value
	end
	
	def uint16
		if @firmware.size > @pc
			value = @firmware[@pc...@pc+2].unpack 'v'
		else
			raise "PC out of bounds: %08x" % @pc
		end
		@pc += 2
	end
	
	def push(value, size)
		sp = reg.word[7] - (size >> 3)
		reg.word[7] = sp
		case size
			when 8
				mem.byte[sp] = value
			when 16
				mem.word[sp] = value
			when 24
				mem.pc[sp] = value
		end
	end
	
	def pop(size)
		sp = reg.word[7]
		case size
			when 8
				value = mem.byte[sp]
			when 16
				value = mem.word[sp]
			when 24
				value = mem.pc[sp]
		end
		
		reg.word[7] = sp + (size >> 3)
		value
	end
	
	def branch(addr, type=:branch)
		@pc = addr
		if type == :call
			@funcs[@funcs.size] = addr if not @funcs.include? addr
		end
		@blocks[@blocks.size] = addr if not @blocks.include? addr
	end
	
	def uint(size)
		case size
			when :byte
				uint8
			when :word
				(uint8 << 8) | uint8
		end
	end
	
	def directref(size, direct)
		if direct < 0x400
			mem.ref size, direct
		else
			sfr.ref size, direct
		end
	end
	
	def parse(format, size)
		return [] if format == nil
		
		case format
			when 'R,#data'
				dest, data = (uint8 >> 4), uint(size)
				[reg.ref(size, dest), data]
			when 'R,#data4'
				a = uint8
				dest, data = a >> 4, a & 0xF
				[reg.ref(size, dest), data]
			when 'direct,R'
				a = uint8
				src = a >> 4
				direct = ((a & 0x7) << 8) | uint8
				[directref(size, direct), reg.ref(size, src)]
			when 'direct,#data'
				direct = ((uint8 & 0xF0) << 4) | uint8
				data = uint size
				[directref(size, direct), data]
			when 'direct,#data4'
				a = uint8
				direct = ((a & 0xF0) << 4) | uint8
				[directref(size, direct), a & 0xF]
			else
				raise 'Unknown format to parse: ' + format
		end
	end
	
	def execute
		start = @pc
		begin
			if @verbose
				_regs = (0...8).map { |i| '%04x' % reg.word[i] }.to_a
				pp ['%08x' % @pc] + _regs
			end
			
			if not @first and @breakpoints.include? @pc
				raise 'Breakpoint hit at 0x%08x' % @pc
			end
			@first = false
			
			opcd = uint8
			if not $opcodes.include? opcd
				raise 'Unknown opcode: 0x%02X at 0x%08X' % [opcd, @pc-1]
			end
			block = $opcodes[opcd]
			if block != nil
				instance_eval &block
			end
			true
		rescue RuntimeError => e
			@pc = start
			puts e
			false
		rescue => e
			@pc = start
			puts e
			puts e.backtrace
			false
		end
	end
	
	def resume
		@first = true
	end
	
	def run
		$interrupted = false
		resume
		while not $interrupted and execute
		end
	end
end
