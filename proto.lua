#!/usr/bin/env luajit

local bit = require("bit")
local ffi = require("ffi")


local proto = {}

-- return base 128 varint string
function proto.toVarint(i)
    assert(math.fmod(i, 1) == 0)
    local result = {}

    while true do
        local b = bit.band(i, 0x7F)
        i = bit.rshift(i, 7)
        if i ~= 0 then -- has more 
            table.insert(result, bit.bor(0x80, b))
        else
            table.insert(result, b)
            break
        end
    end
    return string.char(unpack(result))
end

-- return value and next index
function proto.fromVarint(buff, index)
    assert(type(buff) == "string" and index > 0)
    local result = 0;
    local current = index
    while true do
        local thisByte = string.byte(buff, current) 
        local thisByte2 = bit.band(0x7F, thisByte)
        result = bit.bor(result, bit.lshift(thisByte2, 7*(current-index)))
        current = current + 1
        if bit.band(thisByte, 0x80) == 0 then break end
    end
    return result, current
end

ffi.cdef[[
union bar { uint8_t b[8]; double d; };
]]

--- return 8-byte string with same memory layout from double "d"
function proto.toDouble(dbl)
    local u = ffi.new("union bar", {d=dbl})
    local v = u.b
    return string.char(v[0], v[1], v[2], v[3], 
                       v[4], v[5], v[6], v[7])
end

function proto.fromDouble(buff, index)
    assert(index+7 <= #buff)
    local u = ffi.new("union bar")
    local v = u.b
    v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7] = string.byte(buff, index, index+7)
    return u.d, index+8
end

-- return tag, wire type
function proto.extractKey(k)
    return bit.rshift(k, 3), bit.band(k, 0x7)
end


function proto.findName(tag, prt)
    for k, v in pairs(prt) do
        if v == tag then return k end
    end
    return nil
end


function proto.test()
    function testToVarint(i, ...)
        local str = string.char(...)
        local v = proto.toVarint(i)
        if str ~= v then
            local s1 = table.concat({...}, ",")
            local s2 = table.concat({string.byte(v)}, ",")
            print(string.format("%d expected %s but get %s", i, s1, s2))
        else
            print("pass")
        end

        local v, index = proto.fromVarint(string.char(...), 1)
        if i ~= v or index ~= (#str+1) then
            local s = table.concat({...}, ",")
            print(string.format("%s expected %d but get %d", s, i, v))
        else
            print("pass")
        end
    end
    testToVarint(1, 1)
    testToVarint(2, 2)
    testToVarint(128, 128, 1)
    testToVarint(300, 0xAC, 0x02)
    testToVarint(150, 0x96, 0x01)

    local testData =
    {
        name = "this is name",
        i32  = 1,
        i64  = 2,
        u32  = 3,
        u64  = 4,
        boolean = true,
        dbl  = 123.456789,
    }
    -- name : tag
    local testProto = 
    {
        name    = 1,
        i32     = 2,
        i64     = 3000,
        u32     = 4000,
        u64     = 500000,
        boolean = 600000,
        u32s    = 8,
        dbl     = 101,
    }
    local buff = proto.serialize(testData, testProto)
    local f =io.open("test_output", "w")
    f:write(buff)
    f:close()

    local output = io.popen("cat test_output | protoc --decode_raw", "r")
    for line in output:lines() do
        -- try matching like 500000: 4
        local tag, value = line:match("(%d+):%s*(%d+)")
        if not tag or not value then
            -- try matching like 1: "this is name"
            tag, value = line:match("(%d+):%s*\"(.+)\"")
            if tag and value then
                local name = proto.findName(tonumber(tag), testProto)
                assert(name)
                assert(tostring(testData[name]) == value) 
            end
            -- TODO: handle double like below:
            -- 101: 0x405edd3c07ee0b0b 
        end
    end
    output:close()
    print("pass")

    local r2 = proto.parse(buff, testProto)
    function compareTable(t1, t2)
        function normalize(b)
            if type(b) == "boolean" then
                if b then return 1 else return 0 end
            else 
                return b
            end
        end
        local result = true
        for k, v in pairs(t1) do
            local v2 = t2[k]
            v = normalize(v)
            v2 = normalize(v2)
            if v2 ~= v then 
                return false 
            end
        end
        for k, v in pairs(t2) do
            local v2 = t1[k]
            v = normalize(v)
            v2 = normalize(v2)
            if v2 ~= v then 
                return false 
            end 
        end
        return true
    end
    assert(compareTable(r2, testData), "the parsed table is different than original one")
    print("pass")

    -- test double
    function testDouble(dbl, ...)
        local buf = proto.toDouble(dbl)
        local str = string.char(...)
        if buf ~= str then
            print("expected:")
            print(string.format("proto.toDouble %f -> %s", dbl, table.concat({...}, ",")))
            print("result:")
            print(string.format("proto.toDouble %f -> %s", dbl, table.concat({string.byte(buf,1,#buf)} , ",")))
            return false
        end
       
        local value = proto.fromDouble(str, 1)
        if value ~= dbl then
            print("expected:")
            print(string.format("proto.fromDouble %s -> %f", table.concat({...}, ","), dbl))
            print("result:")
            print(string.format("proto.fromDouble %s -> %f", table.concat({string.byte(buf,1,#buf)} , ","), dbl))
            return false
        end
        return true
    end
    assert(testDouble(1.1, 154, 153, 153, 153, 153, 153, 241, 63))
    assert(testDouble(123.456789, 11, 11, 238, 7, 60, 221, 94, 64))
    assert(testDouble(0, 0, 0, 0, 0, 0, 0, 0, 0))
    print("pass")
end



-- tbl: table value to be serialized
-- prt: protobuf description table
-- return: a string with serialized value
-- 
-- detailed mapping
-- lua type |  prontobuf type
-- string   |  length-delimited (1)
-- double   |  64-bit (2)
-- int      |  varint (0) 

-- note, there is no "int" in lua, 
-- only when math.fmod(x, 1) == 0
function proto.serialize(tbl, prt)
    assert(tbl and prt)
    local result = {}
    for k, v in pairs(tbl) do
        local t = type(v)
        local tag = prt[k]
        if not tag then
            assert(false, "can't find " .. k .. " in proto")
        end
        local key, value
        if t == "string" then
            key = bit.bor(bit.lshift(tag, 3), 2)
            key = proto.toVarint(key)
            value = proto.toVarint(#v) .. v 
        elseif t == "number" then
           if math.fmod(v, 1) == 0 then
                -- varint
                key = bit.bor(bit.lshift(tag, 3), 0)
                key = proto.toVarint(key)
                value = proto.toVarint(v)
            else
                -- double
                key = bit.bor(bit.lshift(tag, 3), 1)
                key = proto.toVarint(key)
                value = proto.toDouble(v) 
            end
        elseif t == "boolean" then
            key = bit.bor(bit.lshift(tag, 3), 0)
            key = proto.toVarint(key)
            value = proto.toVarint(1)
        else
            assert(false, "can't support " .. t)
        end
        table.insert(result, key .. value)
    end
    return table.concat(result)
end

-- str: a string value with serialized value
-- prt: protobuf
-- return: a parsed table value
function proto.parse(str, prt)
    local result = {}
    local len = string.len(str)
    local index = 1
    while index <= len do
        local key 
        key, index = proto.fromVarint(str, index)
        local tag, wire_type = proto.extractKey(key)

        local value
        if wire_type == 0 then
            value, index = proto.fromVarint(str, index)
        elseif wire_type == 1 then
            value, index = proto.fromDouble(str, index) 
        elseif wire_type == 2 then
            local len
            len, index = proto.fromVarint(str, index)
            value = string.sub(str, index, index+len-1)
            index = index + len
        else
            assert(false, "doesn't support wire type " .. wire_type)
        end
        -- set pair in table
        local tagName = proto.findName(tag, prt)
        if tagName and value then
            result[tagName] = value
        else
            assert(false, "can't find the name : " .. name)
        end
    end
    return result
end


if arg ~= nil then
    proto.test()
else
    return proto
end
