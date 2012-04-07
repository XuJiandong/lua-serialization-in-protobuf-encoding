#!/usr/bin/env luajit

local bit = require("bit")
local ffi = require("ffi")


local proto = {}

-- return base 128 varint string
function proto.serializeVarint(i)
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
function proto.parseVarint(buff, index)
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
function proto.serializeDouble(dbl)
    local u = ffi.new("union bar", {d=dbl})
    local v = u.b
    return string.char(v[0], v[1], v[2], v[3], 
                       v[4], v[5], v[6], v[7])
end

function proto.parseDouble(buff, index)
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
    function testSerializeVarint(i, ...)
        local str = string.char(...)
        local v = proto.serializeVarint(i)
        if str ~= v then
            local s1 = table.concat({...}, ",")
            local s2 = table.concat({string.byte(v, 1, #v)}, ",")
            print(string.format("%d expected %s but get %s", i, s1, s2))
        else
            print("pass")
        end

        local v, index = proto.parseVarint(string.char(...), 1)
        if i ~= v or index ~= (#str+1) then
            local s = table.concat({...}, ",")
            print(string.format("%s expected %d but get %d", s, i, v))
        else
            print("pass")
        end
    end
    testSerializeVarint(1, 1)
    testSerializeVarint(2, 2)
    testSerializeVarint(128, 128, 1)
    testSerializeVarint(300, 0xAC, 0x02)
    testSerializeVarint(150, 0x96, 0x01)
    testSerializeVarint(-1, 255, 255, 255, 255, 15)
    testSerializeVarint(-2, 254, 255, 255, 255, 15)

    local testData =
    {
        name = "this is name",
        i32  = 1,
        i64  = 2,
        u32  = 3,
        u64  = 4,
        boolean = true,
        dbl  = 123.456789,
        minus= -100,
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
        minus   = 102,
    }
    local buff = proto.serialize(testData, testProto)
    local f =io.open("test_output", "w")
    f:write(buff)
    f:close()

    local output = io.popen("cat test_output | protoc --decode_raw", "r")
    for line in output:lines() do
        -- try matching like 101: 0x405edd3c07ee0b0b 
        local tag, value = line:match("(%d+):%s*0x(%x+)$")
        if tag and value then
            local hex = {}
            value:gsub("%x%x", function (h) 
                table.insert(hex, tonumber(h, 16)) 
            end) 
            hex = string.char(hex[8], hex[7], hex[6], hex[5],
                            hex[4], hex[3], hex[2], hex[1])
            value = proto.parseDouble(hex, 1)
        end
        if not tag or not value then
            -- try matching like 500000: 4
            tag, value = line:match("(%d+):%s*(%d+)$")
        end
        if not tag or not value then
            -- try matching like 1: "this is name"
            tag, value = line:match("(%d+):%s*\"(.+)\"")
        end
        if tag and value then
            local name = proto.findName(tonumber(tag), testProto)
            assert(name)
            local testValue = testData[name]
            -- boolean
            if type(testData[name]) == "boolean" then testValue = 1 end
            -- nagative number
            if type(testData[name]) == "number" and testData[name] < 0 then
                testValue = 0xFFFFFFFF + testData[name] + 1
            end
            if tostring(testValue) ~= tostring(value) then
                print(string.format("expected: testData[%q] -> ", name) .. tostring(value))
                print(string.format("actually: testData[%q] -> ", name) .. tostring(testData[name]))
            end
        else
            assert(false, "can't match " .. line)
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
        local buf = proto.serializeDouble(dbl)
        local str = string.char(...)
        if buf ~= str then
            print("expected:")
            print(string.format("proto.serializeDouble %f -> %s", dbl, table.concat({...}, ",")))
            print("result:")
            print(string.format("proto.serializeDouble %f -> %s", dbl, table.concat({string.byte(buf,1,#buf)} , ",")))
            return false
        end
       
        local value = proto.parseDouble(str, 1)
        if value ~= dbl then
            print("expected:")
            print(string.format("proto.parseDouble %s -> %f", table.concat({...}, ","), dbl))
            print("result:")
            print(string.format("proto.parseDouble %s -> %f", table.concat({string.byte(buf,1,#buf)} , ","), dbl))
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
            key = proto.serializeVarint(key)
            value = proto.serializeVarint(#v) .. v 
        elseif t == "number" then
           if math.fmod(v, 1) == 0 then
                -- varint
                key = bit.bor(bit.lshift(tag, 3), 0)
                key = proto.serializeVarint(key)
                value = proto.serializeVarint(v)
            else
                -- double
                key = bit.bor(bit.lshift(tag, 3), 1)
                key = proto.serializeVarint(key)
                value = proto.serializeDouble(v) 
            end
        elseif t == "boolean" then
            key = bit.bor(bit.lshift(tag, 3), 0)
            key = proto.serializeVarint(key)
            value = proto.serializeVarint(1)
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
        key, index = proto.parseVarint(str, index)
        local tag, wire_type = proto.extractKey(key)

        local value
        if wire_type == 0 then
            value, index = proto.parseVarint(str, index)
        elseif wire_type == 1 then
            value, index = proto.parseDouble(str, index) 
        elseif wire_type == 2 then
            local len
            len, index = proto.parseVarint(str, index)
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
