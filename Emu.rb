require 'Cpu'
require 'Loader'

$interrupted = false
trap('INT') do
	$interrupted = true
end

class Emu
	def initialize(fn)
		@firmware = load fn
		
		@verbose = false
		cmd_reset
		
		while true
			print 'XppEmu @0x%08x> ' % @cpu.pc
			line = STDIN.gets
			break if line == nil
			line = line.chomp.split ' '
			next if line.size == 0
			
			cmd = ('cmd_' + line[0]).to_sym
			if not public_methods.include? cmd
				puts 'Unknown command'
				next
			end
			meth = method cmd
			meth.call *line[1...line.size]
		end
	end
	
	def cmd_quit
		exit
	end
	
	def cmd_stats
		puts 'Hit %i functions and %i basic blocks.' % [@cpu.funcs.size, @cpu.blocks.size]
		count = 0
		(0...256).each do |i|
			count += 1 if $opcodes.include? i
		end
		puts 'Implemented %i/256 opcodes' % count 
	end
	
	def cmd_run
		@cpu.run
	end
	
	def cmd_verbose
		@verbose = @cpu.toggle_verbose
		if @verbose
			puts 'Verbose == true'
		else
			puts 'Verbose == false'
		end
	end
	
	def cmd_reset
		bps = []
		bps = @cpu.breakpoints if @cpu != nil
		
		@cpu = Cpu.new @firmware
		@cpu.toggle_verbose if @verbose
		bps.each do |bp|
			@cpu.add_bp bp
		end
	end
	
	def cmd_break(addr) cmd_bp addr end
	def cmd_bp(addr)
		addr = addr.hex
		if @cpu.add_bp addr
			puts 'Breakpoint added at 0x%08x' % addr
		else
			puts 'Breakpoint deleted at 0x%08x' % addr
		end
	end
	
	def cmd_step
		@cpu.resume
		@cpu.execute
	end
	
	def cmd_regs
		puts 'PC: %08X' % @cpu.pc
		(0...16).each do |i|
			puts 'R%i: %04X' % [i, @cpu.reg.word[i]]
		end
	end
	
	def cmd_eval(*stmt)
		stmt = stmt.join ' '
		
		value = @cpu.instance_eval stmt
		puts '%08x' % value
	end
	
	def cmd_tracereg(reg)
		if reg[0] == 'r' or reg[0] == 'R'
			reg = reg[1...reg.size].to_i
		else
			reg = reg.to_i
		end
		
		if @cpu.tracereg reg
			puts 'Added register trace for R%i' % reg
		else
			puts 'Deleted register trace for R%i' % reg
		end
	end
	
	def cmd_tracemem(*stmt)
		stmt = stmt.join ' '
		
		value = @cpu.instance_eval stmt
		if @cpu.tracemem value
			puts 'Added memory trace for address 0x%08X' % value
		else
			puts 'Deleted memory trace for address 0x%08X' % value
		end
	end
end

Emu.new ARGV[0]
