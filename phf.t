
--Minimal Perfect Hash Function Generator for Lua/Terra.
--Written by Cosmin Apreutesei. Public Domain.

--Generation at compile-time in Lua, lookup at runtime in Terra.
--Supports primitive type keys and values as well as string keys.
--Does not support 0 as value!
--Algorithm from http://stevehanov.ca/blog/index.php?id=119.

local ffi = require'ffi'
local glue = require'glue'
setfenv(1, require'low'.C)

local indexof = glue.indexof
local push = table.insert
local pop = table.remove
local cast = ffi.cast
local voidp_t = ffi.typeof'void*'

local terra fnv_1a_hash(s: &opaque, len: int32, d: uint32)
	if d == 0 then d = 0x811C9DC5 end
	for i = 0, len do
		d = ((d ^ [&uint8](s)[i]) * 16777619) and 0x7fffffff
	end
	return d
end

local function phf(t, ktype, vtype, thash)
	thash = thash or fnv_1a_hash
	local hash
	if ktype == 'string' then
		hash = function(s, d)
			return thash(cast(voidp_t, s), #s, d or 0)
		end
	else
		local nbuf = terralib.new(ktype[1])
		hash = function(n, d)
			nbuf[0] = n
			return thash(nbuf, sizeof(ktype), d or 0)
		end
	end

	local n = 0
	for k,v in pairs(t) do
		assert(v ~= 0)
		n = n + 1
	end

	local G = terralib.new(int32[n]) --{slot -> +/-d}
	local V = terralib.new(vtype[n]) --{d -> val; -d-1 -> val}

	--place all keys into buckets and sort the buckets
	--so that the buckets with most keys are processed first.
	local buckets = {} --{hash -> {k1, ...}}
	for i = 1, n do
		buckets[i] = {}
	end
	for k in pairs(t) do
		push(buckets[(hash(k) % n) + 1], k)
	end
	table.sort(buckets, function(a, b) return #a > #b end)

	local tries = 0
	for b = 1, n do
		local bucket = buckets[b]
		if #bucket > 1 then
			--bucket has multiple keys: try different values of d until
			--a perfect hash function is found for those keys.
			local d = 1
			local slots = {} --{slot1,...}
			local i = 1
			while i <= #bucket do
				local slot = hash(bucket[i], d) % n
				if V[slot] ~= 0 or indexof(slot, slots) then
					if d >= 10000 then
						error('could not find a phf in '..d..' tries.')
					end
					d = d + 1
					tries = tries + 1
					i = 1
					slots = {}
				else
					push(slots, slot)
					i = i + 1
				end
			end
			G[hash(bucket[1]) % n] = d
			for i = 1, #bucket do
				V[slots[i]] = t[bucket[i]]
			end
		else
			--place all buckets with one key directly into a free slot.
			--use a negative value of d to indicate that.
			local freelist = {} --{slot1, ...}
			for slot = 0, n-1 do
				if V[slot] == 0 then
					push(freelist, slot)
				end
			end
			for b = b, n do
				local bucket = buckets[b]
				if #bucket == 0 then
					break
				end
				local slot = pop(freelist)
				G[hash(bucket[1]) % n] = -slot-1
				V[slot] = t[bucket[1]]
			end
			break
		end
	end

	local self = {tries = tries}

	local G = constant(G)
	local V = constant(V)
	local hash = thash

	if ktype == 'string' then
		terra self.lookup(k: &int8, len: int32)
			var d = G[hash(k, len, 0) % n]
			if d < 0 then
				return V[-d-1]
			else
				return V[hash(k, len, d) % n]
			end
		end
	else
		terra self.lookup(k: ktype)
			var d = G[hash(&k, sizeof(ktype), 0) % n]
			if d < 0 then
				return V[-d-1]
			else
				return V[hash(&k, sizeof(ktype), d) % n]
			end
		end
	end

	return self
end

if not ... then --testing

	local clock = require'time'.clock

	local function read_words(file)
		local t = {}
		local i = 0
		for s in io.lines(file) do
			i = i + 1
			t[s:gsub('[\n\r]', '')] = i
		end
		t.n = i
		return t
	end

	local function test_strings(t)
		print'testing strings...'
		local t0 = clock()
		local map = phf(t, 'string', uint32)
		print(string.format(' time for %d items: %dms (second tries: %d).',
			t.n, (clock() - t0) * 1000, map.tries))

		for k,i in pairs(t) do
			assert(map.lookup(k, #k) == i)
		end
		print' no collisons detected.'
	end

	local function test_int32(n, cov)
		print('testing int32s (key space coverage: '..(cov * 100)..'%)...')
		local t = {}
		for i = 1, n do
			t[math.random(n / cov)] = -i
		end
		local t0 = clock()
		local map = phf(t, int32, int32)
		print(string.format(' time for %d items: %dms (second tries: %d).',
			n, (clock() - t0) * 1000, map.tries))

		for k,i in pairs(t) do
			assert(map.lookup(k) == i)
		end
		print' no collisons detected.'
	end

	test_strings(read_words'media/phf/words')
	test_int32(10, 1)
	test_int32(100000, 1)
	test_int32(100000, .5)

end

return phf

