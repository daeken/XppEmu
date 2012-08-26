def load(fn)
	if File.exists? fn + '.bin'
		return File.open(fn + '.bin', 'rb').read
	end
	
	fp = File.open fn
	
	buffer = [0] * (65536 * 4)
	offset = 0
	
	fp.each do |line|
		line.strip!
		next if line[0] != ':'
		
		line = [line[1...line.size]].pack 'H*'
		
		count, addr, type = line.unpack 'CnC'
		addr += offset
		
		case type
			when 0
				buffer[addr...addr+count] = line[4...4+count].unpack 'C*'
			when 1
				break
			when 2
				offset = line[4...6].unpack('n')[0] << 4
		end
	end
	
	buffer = buffer.pack 'C*'
	File.open(fn + '.bin', 'wb').write buffer
	buffer
end
