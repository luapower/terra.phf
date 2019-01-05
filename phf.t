
--Minimal Perfect Hash Function Generator for Lua/Terra.
--Written by Cosmin Apreutesei. Public Domain.

--Generation at compile-time in Lua, lookup at runtime in Terra.
--Supports primitive type keys and values as well as string keys.
--One value must be specified as invalid and not used (defaults to 0/nil)!
--Algorithm from http://stevehanov.ca/blog/index.php?id=119.

local ffi = require'ffi'
local glue = require'glue'
setfenv(1, require'low'.C)
include'string.h'

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

local function phf_fp(t, ktype, vtype, invalid_value, thash)
	thash = thash or fnv_1a_hash
	if invalid_value == nil and not vtype:ispointer() then
		invalid_value = 0
	end
	local hash
	if ktype == 'string' then
		hash = function(s, d)
			return thash(cast(voidp_t, s), #s, d or 0)
		end
	else
		local valbuf = terralib.new(ktype[1])
		hash = function(v, d)
			valbuf[0] = v
			return thash(valbuf, sizeof(ktype), d or 0)
		end
	end

	local n = 0
	for k,v in pairs(t) do
		assert(v ~= invalid_value)
		n = n + 1
	end

	local G = terralib.new(int32[n]) --{slot -> d|-d-1}
	local V = terralib.new(vtype[n], invalid_value) --{d|-d-1 -> val}

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
				if V[slot] ~= invalid_value or glue.indexof(slot, slots) then
					if d >= 10000 then
						error('could not find a phf in '..d..' tries for key '..bucket[i])
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
				if V[slot] == invalid_value then
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

--NOTE: a simple phf returns a false positive when looking up a key that is
--not from the initial key set. So we keep the keys around and check the
--validity of the result against.
--TODO: Hash and anchor string keys!
local function phf_nofp(t, ktype, vtype, invalid_value, thash)
	if invalid_value == nil and not vtype:ispointer() then
		invalid_value = 0
	end
	local n = glue.count(t)
	local it = {} --{key -> index_in_vt}
	local str = ktype == 'string'
	local Ktype = str and &int8 or ktype
	local K = terralib.new(Ktype[n]) --{index -> key}
	local V = terralib.new(vtype[n]) --{index -> val}
	local i = 0
	for k,v in pairs(t) do
		it[k] = i
		K[i] = k
		V[i] = v
		i = i + 1
	end
	local map = phf_fp(it, ktype, int32, -1, thash)
	local lookup = map.lookup
	local K = constant(K)
	local V = constant(V)
	if str then
		map.lookup = terra(k: &int8, len: int32)
			var i = lookup(k, len)
			if memcmp(k, K[i], len) == 0 then
				return V[i]
			else
				return invalid_value
			end
		end
	else
		map.lookup = terra(k: ktype)
			var i = lookup(k)
			if K[i] == k then
				return V[i]
			else
				return invalid_value
			end
		end
	end
	return map
end

local function phf(t, ktype, vtype, invalid_value, complete_set, thash)
	local phf = complete_set and phf_fp or phf_nofp
	return phf(t, ktype, vtype, invalid_value, thash)
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
		return t
	end

	local function gen_numbers(n, cov)
		local t = {}
		for i = 1, n do
			t[math.random(n / cov)] = -i
		end
		return t
	end

	local function test(t, ktype, vtype, invalid_value, complete_set, cov)
		local n = glue.count(t)
		print(n..' items, '
			..tostring(ktype)..'->'..tostring(vtype)
			..', key space coverage: '..(cov or 'n/a')
		)
		local t0 = clock()
		local map = phf(t, ktype, vtype, invalid_value, complete_set)
		io.stdout:write(string.format(' time: %dms, second tries: %d.',
			(clock() - t0) * 1000, map.tries))

		for k,i in pairs(t) do
			if ktype == 'string' then
				assert(map.lookup(k, #k) == i)
			else
				assert(map.lookup(k) == i)
			end
		end
		print' ok.'
		return map
	end

	local map = test(read_words'media/phf/words', 'string', int32, nil, true)
	--TODO: make phf_nofp work with strings.
	--assert(map.lookup('invalid word', #'invalid word') == nil)
	local map = test(gen_numbers(10, 1), int32, int32, -1, nil, 1)
	assert(map.lookup(20) == -1)
	local map = test(gen_numbers(100000, 1), int32, int32, nil, nil, 1)
	assert(map.lookup(500000) == 0)
	local map = test(gen_numbers(100000, .5), int32, int32, 0, nil, .5)
	assert(map.lookup(500000) == 0)

end

return phf
