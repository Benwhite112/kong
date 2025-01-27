local propagation = require "kong.tracing.propagation"

local to_hex = require "resty.string".to_hex

local table_merge = require "kong.tools.utils".table_merge

local fmt  = string.format

local openssl_bignumber = require "resty.openssl.bn"

local function to_hex_ids(arr)
  return { arr[1],
           arr[2] and to_hex(arr[2]) or nil,
           arr[3] and to_hex(arr[3]) or nil,
           arr[4] and to_hex(arr[4]) or nil,
           arr[5] }
end

local function left_pad_zero(str, count)
  return ('0'):rep(count-#str) .. str
end

local function to_id_len(id, len)
  if #id < len then
    return string.rep('0', len - #id) .. id
  elseif #id > len then
    return string.sub(id, -len)
  end

  return id
end

local parse = propagation.parse
local set = propagation.set
local from_hex = propagation.from_hex

local trace_id = "0000000000000001"
local big_trace_id = "fffffffffffffff1"
local big_parent_id = "fffffffffffffff2"
local trace_id_32 = "00000000000000000000000000000001"
local big_trace_id_32 = "fffffffffffffffffffffffffffffff1"
local parent_id = "0000000000000002"
local span_id = "0000000000000003"
local big_span_id = "fffffffffffffff3"
local non_hex_id = "vvvvvvvvvvvvvvvv"
local too_short_id = "123"
local too_long_id = "1234567890123456789012345678901234567890" -- 40 digits

describe("propagation.parse", function()

  _G.kong = {
    log = {},
  }

  describe("b3 single header parsing", function()
    local warn, debug
    setup(function()
      warn = spy.on(kong.log, "warn")
      debug = spy.on(kong.log, "debug")
    end)
    before_each(function()
      warn:clear()
      debug:clear()
    end)
    teardown(function()
      warn:revert()
      debug:clear()
    end)

    it("does not parse headers with ignore type", function()
      local b3 = fmt("%s-%s-%s-%s", trace_id, span_id, "1", parent_id)
      local t = { parse({ tracestate = "b3=" .. b3 }, "ignore") }
      assert.spy(warn).not_called()
      assert.same({}, t)
    end)

    it("1-char", function()
      local t  = { parse({ b3 = "1" }) }
      assert.same({ "b3-single", nil, nil, nil, true }, t)
      assert.spy(warn).not_called()

      t  = { parse({ b3 = "d" }) }
      assert.same({ "b3-single", nil, nil, nil, true }, t)
      assert.spy(warn).not_called()

      t  = { parse({ b3 = "0" }) }
      assert.same({ "b3-single", nil, nil, nil, false }, t)
      assert.spy(warn).not_called()
    end)

    it("4 fields", function()
      local b3 = fmt("%s-%s-%s-%s", trace_id, span_id, "1", parent_id)
      local t = { parse({ b3 = b3 }) }
      assert.same({ "b3-single", trace_id, span_id, parent_id, true }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("4 fields inside traceparent", function()
      local b3 = fmt("%s-%s-%s-%s", trace_id, span_id, "1", parent_id)
      local t = { parse({ tracestate = "b3=" .. b3 }) }
      assert.same({ "b3-single", trace_id, span_id, parent_id, true }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("32-digit trace_id", function()
      local b3 = fmt("%s-%s-%s-%s", trace_id_32, span_id, "1", parent_id)
      local t = { parse({ b3 = b3 }) }
      assert.same({ "b3-single", trace_id_32, span_id, parent_id, true }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("trace_id and span_id, no sample or parent_id", function()
      local b3 = fmt("%s-%s", trace_id, span_id)
      local t = { parse({ b3 = b3 }) }
      assert.same({ "b3-single", trace_id, span_id }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("32-digit trace_id and span_id, no sample or parent_id", function()
      local b3 = fmt("%s-%s", trace_id_32, span_id)
      local t = { parse({ b3 = b3 }) }
      assert.same({ "b3-single", trace_id_32, span_id }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("trace_id, span_id and sample, no parent_id", function()
      local b3 = fmt("%s-%s-%s", trace_id, span_id, "1")
      local t = { parse({ b3 = b3 }) }
      assert.same({ "b3-single", trace_id, span_id, nil, true }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("32-digit trace_id, span_id and sample, no parent_id", function()
      local b3 = fmt("%s-%s-%s", trace_id_32, span_id, "1")
      local t = { parse({ b3 = b3 }) }
      assert.same({ "b3-single", trace_id_32, span_id, nil, true }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("big 32-digit trace_id, span_id and sample, no parent_id", function()
      local b3 = fmt("%s-%s-%s", big_trace_id_32, span_id, "1")
      local t = { parse({ b3 = b3 }) }
      assert.same({ "b3-single", big_trace_id_32, span_id, nil, true }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("sample debug = always sample", function()
      local b3 = fmt("%s-%s-%s-%s", trace_id, span_id, "d", parent_id)
      local t  = { parse({ b3 = b3 }) }
      assert.same({ "b3-single", trace_id, span_id, parent_id, true }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("sample 0 = don't sample", function()
      local b3 = fmt("%s-%s-%s-%s", trace_id, span_id, "0", parent_id)
      local t  = { parse({ b3 = b3 }) }
      assert.same({ "b3-single", trace_id, span_id, parent_id, false }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("sample 0 overridden by x-b3-sampled", function()
      local b3 = fmt("%s-%s-%s-%s", trace_id, span_id, "0", parent_id)
      local t  = { parse({ b3 = b3, ["x-b3-sampled"] = "1" }) }
      assert.same({ "b3-single", trace_id, span_id, parent_id, true }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("multi value tracestate header", function()
      local tracestate_header = { "test", trace_id, span_id }
      local t = { parse({ tracestate =  tracestate_header }) }
      assert.same({ }, to_hex_ids(t))
      assert.spy(debug).called(1)
    end)

    describe("errors", function()
      it("requires trace id", function()
        local t = { parse({ b3 = "" }) }
        assert.same({"b3-single"}, t)
        assert.spy(warn).called_with("b3 single header invalid; ignoring.")
      end)

      it("rejects existing but invalid trace_id", function()
        local t = { parse({ b3 = non_hex_id .. "-" .. span_id }) }
        assert.same({"b3-single"}, t)
        assert.spy(warn).called_with("b3 single header invalid; ignoring.")

        t = { parse({ b3 = too_short_id .. "-" .. span_id }) }
        assert.same({"b3-single"}, t)
        assert.spy(warn).called_with("b3 single header invalid; ignoring.")

        -- too long
        t = { parse({ b3 = too_long_id .. "-" .. span_id }) }
        assert.same({"b3-single"}, t)
        assert.spy(warn).called_with("b3 single header invalid; ignoring.")
      end)

      it("requires span_id", function()
        local t = { parse({ b3 = trace_id .. "-" }) }
        assert.same({"b3-single"}, t)
        assert.spy(warn).called_with("b3 single header invalid; ignoring.")
      end)

      it("rejects existing but invalid span_id", function()
        local t = { parse({ b3 = trace_id .. non_hex_id }) }
        assert.same({"b3-single"}, t)
        assert.spy(warn).called_with("b3 single header invalid; ignoring.")

        t = { parse({ b3 = trace_id .. too_short_id }) }
        assert.same({"b3-single"}, t)
        assert.spy(warn).called_with("b3 single header invalid; ignoring.")

        t = { parse({ b3 = trace_id .. too_long_id }) }
        assert.same({"b3-single"}, t)
        assert.spy(warn).called_with("b3 single header invalid; ignoring.")
      end)

      it("rejects invalid sampled section", function()
        local b3 = fmt("%s-%s-%s-%s", trace_id, span_id, "x", parent_id)
        local t  = { parse({ b3 = b3 }) }
        assert.same({"b3-single"}, t)
        assert.spy(warn).called_with("b3 single header invalid; ignoring.")
      end)

      it("rejects invalid parent_id section", function()
        local b3 = fmt("%s-%s-%s-%s", trace_id, span_id, "d", non_hex_id)
        local t  = { parse({ b3 = b3 }) }
        assert.same({"b3-single"}, t)
        assert.spy(warn).called_with("b3 single header invalid; ignoring.")

        b3 = fmt("%s-%s-%s-%s", trace_id, span_id, "d", too_short_id)
        t  = { parse({ b3 = b3 }) }
        assert.same({"b3-single"}, t)
        assert.spy(warn).called_with("b3 single header invalid; ignoring.")

        b3 = fmt("%s-%s-%s-%s", trace_id, span_id, "d", too_long_id)
        t  = { parse({ b3 = b3 }) }
        assert.same({"b3-single"}, t)
        assert.spy(warn).called_with("b3 single header invalid; ignoring.")
      end)
    end)
  end)

  describe("W3C header parsing", function()
    local warn
    setup(function()
      warn = spy.on(kong.log, "warn")
    end)
    before_each(function()
      warn:clear()
    end)
    teardown(function()
      warn:revert()
    end)

    it("valid traceparent with sampling", function()
      local traceparent = fmt("00-%s-%s-01", trace_id_32, parent_id)
      local t = { parse({ traceparent = traceparent }) }
      assert.same({ "w3c", trace_id_32, nil, parent_id, true }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("valid traceparent without sampling", function()
      local traceparent = fmt("00-%s-%s-00", trace_id_32, parent_id)
      local t = { parse({ traceparent = traceparent }) }
      assert.same({ "w3c", trace_id_32, nil, parent_id, false }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("sampling with mask", function()
      local traceparent = fmt("00-%s-%s-09", trace_id_32, parent_id)
      local t = { parse({ traceparent = traceparent }) }
      assert.same({ "w3c", trace_id_32, nil, parent_id, true }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("no sampling with mask", function()
      local traceparent = fmt("00-%s-%s-08", trace_id_32, parent_id)
      local t = { parse({ traceparent = traceparent }) }
      assert.same({ "w3c", trace_id_32, nil, parent_id, false }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    describe("errors", function()
      it("rejects traceparent versions other than 00", function()
        local traceparent = fmt("01-%s-%s-00", trace_id_32, parent_id)
        local t = { parse({ traceparent = traceparent }) }
        assert.same({ "w3c" }, t)
        assert.spy(warn).was_called_with("invalid W3C Trace Context version; ignoring.")
      end)

      it("rejects invalid header", function()
        local traceparent = "vv-00000000000000000000000000000001-0000000000000001-00"
        local t = { parse({ traceparent = traceparent }) }
        assert.same({ "w3c" }, t)
        assert.spy(warn).was_called_with("invalid W3C traceparent header; ignoring.")

        traceparent = "00-vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv-0000000000000001-00"
        t = { parse({ traceparent = traceparent }) }
        assert.same({ "w3c" }, t)
        assert.spy(warn).was_called_with("invalid W3C traceparent header; ignoring.")

        traceparent = "00-00000000000000000000000000000001-vvvvvvvvvvvvvvvv-00"
        t = { parse({ traceparent = traceparent }) }
        assert.same({ "w3c" }, t)
        assert.spy(warn).was_called_with("invalid W3C traceparent header; ignoring.")

        traceparent = "00-00000000000000000000000000000001-0000000000000001-vv"
        t = { parse({ traceparent = traceparent }) }
        assert.same({ "w3c" }, t)
        assert.spy(warn).was_called_with("invalid W3C traceparent header; ignoring.")
      end)

      it("rejects invalid trace IDs", function()
        local traceparent = fmt("00-%s-%s-00", too_short_id, parent_id)
        local t = { parse({ traceparent = traceparent }) }
        assert.same({ "w3c" }, t)
        assert.spy(warn).was_called_with("invalid W3C trace context trace ID; ignoring.")

        traceparent = fmt("00-%s-%s-00", too_long_id, parent_id)
        t = { parse({ traceparent = traceparent }) }
        assert.same({ "w3c" }, t)
        assert.spy(warn).was_called_with("invalid W3C trace context trace ID; ignoring.")

        -- cannot be all zeros
        traceparent = fmt("00-00000000000000000000000000000000-%s-00", too_long_id, parent_id)
        t = { parse({ traceparent = traceparent }) }
        assert.same({ "w3c" }, t)
        assert.spy(warn).was_called_with("invalid W3C trace context trace ID; ignoring.")
      end)

      it("rejects invalid parent IDs", function()
        local traceparent = fmt("00-%s-%s-00", trace_id_32, too_short_id)
        local t = { parse({ traceparent = traceparent }) }
        assert.same({ "w3c" }, t)
        assert.spy(warn).was_called_with("invalid W3C trace context parent ID; ignoring.")

        traceparent = fmt("00-%s-%s-00", trace_id_32, too_long_id)
        t = { parse({ traceparent = traceparent }) }
        assert.same({ "w3c" }, t)
        assert.spy(warn).was_called_with("invalid W3C trace context parent ID; ignoring.")

        -- cannot be all zeros
        traceparent = fmt("00-%s-0000000000000000-01", trace_id_32)
        t = { parse({ traceparent = traceparent }) }
        assert.same({ "w3c" }, t)
        assert.spy(warn).was_called_with("invalid W3C trace context parent ID; ignoring.")
      end)

      it("rejects invalid trace flags", function()
        local traceparent = fmt("00-%s-%s-000", trace_id_32, parent_id)
        local t = { parse({ traceparent = traceparent }) }
        assert.same({ "w3c" }, t)
        assert.spy(warn).was_called_with("invalid W3C trace context flags; ignoring.")

        traceparent = fmt("00-%s-%s-0", trace_id_32, parent_id)
        t = { parse({ traceparent = traceparent }) }
        assert.same({ "w3c" }, t)
        assert.spy(warn).was_called_with("invalid W3C trace context flags; ignoring.")
      end)
    end)
  end)


  describe("Jaeger header parsing", function()
    local warn
    setup(function()
      warn = spy.on(kong.log, "warn")
    end)
    before_each(function()
      warn:clear()
    end)
    teardown(function()
      warn:revert()
    end)

    it("valid uber-trace-id with sampling", function()
      local ubertraceid = fmt("%s:%s:%s:%s", trace_id, span_id, parent_id, "1")
      local t = { parse({ ["uber-trace-id"] = ubertraceid }) }
      assert.same({ "jaeger", left_pad_zero(trace_id, 32), span_id, parent_id, true }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("valid uber-trace-id without sampling", function()
      local ubertraceid = fmt("%s:%s:%s:%s", trace_id, span_id, parent_id, "0")
      local t = { parse({ ["uber-trace-id"] = ubertraceid }) }
      assert.same({ "jaeger", left_pad_zero(trace_id, 32), span_id, parent_id, false }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("valid uber-trace-id 128bit with sampling", function()
      local ubertraceid = fmt("%s:%s:%s:%s", trace_id_32, span_id, parent_id, "1")
      local t = { parse({ ["uber-trace-id"] = ubertraceid }) }
      assert.same({ "jaeger", trace_id_32, span_id, parent_id, true }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("valid uber-trace-id 128bit without sampling", function()
      local ubertraceid = fmt("%s:%s:%s:%s", trace_id_32, span_id, parent_id, "0")
      local t = { parse({ ["uber-trace-id"] = ubertraceid }) }
      assert.same({ "jaeger", trace_id_32, span_id, parent_id, false }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("valid uber-trace-id with parent_id 0", function()
      local ubertraceid = fmt("%s:%s:%s:%s", trace_id, span_id, "0", "1")
      local t = { parse({ ["uber-trace-id"] = ubertraceid }) }
      assert.same({ "jaeger", left_pad_zero(trace_id, 32), span_id, to_hex("0"), true }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    describe("errors", function()
      it("rejects invalid header", function()
        local ubertraceid = fmt("vv:%s:%s:%s", span_id, parent_id, "0")
        local t = { parse({ ["uber-trace-id"] = ubertraceid }) }
        assert.same({ "jaeger" }, t)
        assert.spy(warn).was_called_with("invalid jaeger uber-trace-id header; ignoring.")

        ubertraceid = fmt("%s:vv:%s:%s", trace_id, parent_id, "0")
        t = { parse({ ["uber-trace-id"] = ubertraceid }) }
        assert.same({ "jaeger" }, t)
        assert.spy(warn).was_called_with("invalid jaeger uber-trace-id header; ignoring.")

        ubertraceid = fmt("%s:%s:vv:%s", trace_id, span_id,  "0")
        t = { parse({ ["uber-trace-id"] = ubertraceid }) }
        assert.same({ "jaeger" }, t)
        assert.spy(warn).was_called_with("invalid jaeger uber-trace-id header; ignoring.")

        ubertraceid = fmt("%s:%s:%s:vv", trace_id, span_id, parent_id)
        t = { parse({ ["uber-trace-id"] = ubertraceid }) }
        assert.same({ "jaeger" }, t)
        assert.spy(warn).was_called_with("invalid jaeger uber-trace-id header; ignoring.")
      end)

      it("rejects invalid trace IDs", function()
        local ubertraceid = fmt("%s:%s:%s:%s", too_long_id, span_id, parent_id, "1")
        local t = { parse({ ["uber-trace-id"] = ubertraceid }) }
        assert.same({ "jaeger" }, t)
        assert.spy(warn).was_called_with("invalid jaeger trace ID; ignoring.")

        -- cannot be all zeros
        ubertraceid = fmt("%s:%s:%s:%s", "00000000000000000000000000000000", span_id, parent_id, "1")
        t = { parse({ ["uber-trace-id"] = ubertraceid }) }
        assert.same({ "jaeger" }, t)
        assert.spy(warn).was_called_with("invalid jaeger trace ID; ignoring.")
      end)

      it("rejects invalid parent IDs", function()
        -- Ignores invalid parent id and logs
        local ubertraceid = fmt("%s:%s:%s:%s", trace_id, span_id, too_short_id, "1")
        local t = { parse({ ["uber-trace-id"] = ubertraceid }) }
        -- Note: to_hex(from_hex()) for too_short_id as the binary conversion from hex is resulting in a different number
        assert.same({ "jaeger", left_pad_zero(trace_id, 32), span_id, to_hex(from_hex(too_short_id)), true }, to_hex_ids(t))
        assert.spy(warn).was_called_with("invalid jaeger parent ID; ignoring.")

        -- Ignores invalid parent id and logs
        ubertraceid = fmt("%s:%s:%s:%s", trace_id, span_id, too_long_id, "1")
        t = { parse({ ["uber-trace-id"] = ubertraceid }) }
        assert.same({ "jaeger", left_pad_zero(trace_id, 32), span_id, too_long_id, true }, to_hex_ids(t))
        assert.spy(warn).was_called_with("invalid jaeger parent ID; ignoring.")
      end)

      it("rejects invalid span IDs", function()
        local ubertraceid = fmt("%s:%s:%s:%s", trace_id, too_long_id, parent_id, "1")
        local t = { parse({ ["uber-trace-id"] = ubertraceid }) }
        assert.same({ "jaeger" }, t)
        assert.spy(warn).was_called_with("invalid jaeger span ID; ignoring.")

        -- cannot be all zeros
        ubertraceid = fmt("%s:%s:%s:%s", trace_id, "00000000000000000000000000000000", parent_id, "1")
        t = { parse({ ["uber-trace-id"] = ubertraceid }) }
        assert.same({ "jaeger" }, t)
        assert.spy(warn).was_called_with("invalid jaeger span ID; ignoring.")
      end)

      it("rejects invalid trace flags", function()
        local ubertraceid = fmt("%s:%s:%s:%s", trace_id, span_id, parent_id, "123")
        local t = { parse({ ["uber-trace-id"] = ubertraceid }) }
        assert.same({ "jaeger" }, t)
        assert.spy(warn).was_called_with("invalid jaeger flags; ignoring.")
      end)

      it("0-pad shorter span IDs", function()
        local ubertraceid = fmt("%s:%s:%s:%s", trace_id, too_short_id, parent_id, "1")
        local t = { parse({ ["uber-trace-id"] = ubertraceid }) }
        assert.same({ "jaeger", left_pad_zero(trace_id, 32), left_pad_zero(too_short_id, 16), parent_id, true }, to_hex_ids(t))
      end)

      it("0-pad shorter trace IDs", function()
        local ubertraceid = fmt("%s:%s:%s:%s", too_short_id, span_id, parent_id, "1")
        local t = { parse({ ["uber-trace-id"] = ubertraceid }) }
        assert.same({ "jaeger", left_pad_zero(too_short_id, 32), span_id, parent_id, true }, to_hex_ids(t))
      end)
    end)
  end)


  describe("OT header parsing", function()
    local warn
    setup(function()
      warn = spy.on(kong.log, "warn")
    end)
    before_each(function()
      warn:clear()
    end)
    teardown(function()
      warn:revert()
    end)

    it("valid trace_id, valid span_id, sampled", function()
      local t = { parse({
        ["ot-tracer-traceid"] = trace_id,
        ["ot-tracer-spanid"] = span_id,
        ["ot-tracer-sampled"] = "1",
      })}
      assert.same({ "ot", trace_id, nil, span_id, true }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("valid big trace_id, valid big span_id, sampled", function()
      local t = { parse({
        ["ot-tracer-traceid"] = big_trace_id,
        ["ot-tracer-spanid"] = big_span_id,
        ["ot-tracer-sampled"] = "1",
      })}
      assert.same({ "ot", big_trace_id, nil, big_span_id, true }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("valid trace_id, valid span_id, not sampled", function()
      local t = { parse({
        ["ot-tracer-traceid"] = trace_id,
        ["ot-tracer-spanid"] = span_id,
        ["ot-tracer-sampled"] = "0",
      })}
      assert.same({ "ot", trace_id, nil, span_id, false }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("valid trace_id, valid span_id, sampled", function()
      local t = { parse({
        ["ot-tracer-traceid"] = trace_id,
        ["ot-tracer-spanid"] = span_id,
        ["ot-tracer-sampled"] = "1",
      })}
      assert.same({ "ot", trace_id, nil, span_id, true }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("valid trace_id, valid span_id, no sampled flag", function()
      local t = { parse({
        ["ot-tracer-traceid"] = trace_id,
        ["ot-tracer-spanid"] = span_id,
      })}
      assert.same({ "ot", trace_id, nil, span_id }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("32 trace_id, valid span_id, no sampled flag", function()
      local t = { parse({
        ["ot-tracer-traceid"] = trace_id_32,
        ["ot-tracer-spanid"] = span_id,
      })}
      assert.same({ "ot", trace_id_32, nil, span_id }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("big 32 trace_id, valid big_span_id, no sampled flag", function()
      local t = { parse({
        ["ot-tracer-traceid"] = big_trace_id_32,
        ["ot-tracer-spanid"] = big_span_id,
      })}
      assert.same({ "ot", big_trace_id_32, nil, big_span_id }, to_hex_ids(t))
      assert.spy(warn).not_called()
    end)

    it("valid trace_id, valid span_id, sampled, valid baggage added", function()
      local mock_key = "mock_key"
      local mock_value = "mock_value"
      local t = { parse({
        ["ot-tracer-traceid"] = trace_id,
        ["ot-tracer-spanid"] = span_id,
        ["ot-tracer-sampled"] = "1",
        ["ot-baggage-"..mock_key] = mock_value
      })}
      local mock_baggage_index = t[6]
      assert.same({ "ot", trace_id, nil, span_id, true }, to_hex_ids(t))
      assert.same(mock_baggage_index.mock_key, mock_value)
      assert.spy(warn).not_called()
    end)

    it("valid trace_id, valid span_id, sampled, invalid baggage added", function()
      local t = { parse({
        ["ot-tracer-traceid"] = trace_id,
        ["ot-tracer-spanid"] = span_id,
        ["ot-tracer-sampled"] = "1",
        ["ottttttttbaggage-foo"] = "invalid header"
      })}
      local mock_baggage_index = t[6]
      assert.same({ "ot", trace_id, nil, span_id, true }, to_hex_ids(t))
      assert.same(mock_baggage_index, nil)
      assert.spy(warn).not_called()
    end)
  end)

  describe("aws single header parsing", function()
    local warn, debug
    setup(function()
      warn = spy.on(kong.log, "warn")
      debug = spy.on(kong.log, "debug")
    end)
    before_each(function()
      warn:clear()
      debug:clear()
    end)
    teardown(function()
      warn:revert()
      debug:clear()
    end)

    it("valid aws with sampling", function()
      local aws = fmt("Root=1-%s-%s;Parent=%s;Sampled=%s", string.sub(trace_id_32, 1, 8), string.sub(trace_id_32, 9, #trace_id_32), span_id, "1")
      local t = { parse({["x-amzn-trace-id"] = aws}) }
      assert.spy(warn).not_called()
      assert.same({ "aws", trace_id_32, span_id, nil, true }, to_hex_ids(t))
    end)
    it("valid aws with spaces", function()
      local aws = fmt("    Root =    1-%s-%s   ;   Parent= %s;  Sampled   =%s", string.sub(trace_id_32, 1, 8), string.sub(trace_id_32, 9, #trace_id_32), span_id, "1")
      local t = { parse({["x-amzn-trace-id"] = aws}) }
      assert.spy(warn).not_called()
      assert.same({ "aws", trace_id_32, span_id, nil, true }, to_hex_ids(t))
    end)
    it("valid aws with parent first", function()
      local aws = fmt("Parent=%s;Root=1-%s-%s;Sampled=%s", span_id, string.sub(trace_id_32, 1, 8), string.sub(trace_id_32, 9, #trace_id_32), "1")
      local t = { parse({["x-amzn-trace-id"] = aws}) }
      assert.spy(warn).not_called()
      assert.same({ "aws", trace_id_32, span_id, nil, true }, to_hex_ids(t))
    end)
    it("valid aws with extra fields", function()
      local aws = fmt("Foo=bar;Root=1-%s-%s;Parent=%s;Sampled=%s", string.sub(trace_id_32, 1, 8), string.sub(trace_id_32, 9, #trace_id_32), span_id, "1")
      local t = { parse({["x-amzn-trace-id"] = aws}) }
      assert.spy(warn).not_called()
      assert.same({ "aws", trace_id_32, span_id, nil, true }, to_hex_ids(t))
    end)
    it("valid aws without sampling", function()
      local aws = fmt("Root=1-%s-%s;Parent=%s;Sampled=%s", string.sub(trace_id_32, 1, 8), string.sub(trace_id_32, 9, #trace_id_32), span_id, "0")
      local t = { parse({["x-amzn-trace-id"] = aws}) }
      assert.spy(warn).not_called()
      assert.same({ "aws", trace_id_32, span_id, nil, false }, to_hex_ids(t))
    end)
    it("valid aws with sampling big", function()
      local aws = fmt("Root=1-%s-%s;Parent=%s;Sampled=%s", string.sub(big_trace_id_32, 1, 8), string.sub(big_trace_id_32, 9, #big_trace_id_32), big_span_id, "0")
      local t = { parse({["x-amzn-trace-id"] = aws}) }
      assert.spy(warn).not_called()
      assert.same({ "aws", big_trace_id_32, big_span_id, nil, false }, to_hex_ids(t))
    end)
    describe("errors", function()
      it("rejects invalid trace IDs", function()
        local aws = fmt("Root=0-%s-%s;Parent=%s;Sampled=%s", string.sub(trace_id_32, 1, 8), string.sub(trace_id_32, 9, #trace_id_32), big_span_id, "0")
        local t = { parse({["x-amzn-trace-id"] = aws}) }
        assert.same({ "aws" }, t)
        assert.spy(warn).was_called_with("invalid aws header trace id; ignoring.")

        aws = fmt("Root=1-vv-%s;Parent=%s;Sampled=%s", string.sub(trace_id_32, 9, #trace_id_32), span_id, "0")
        t = { parse({["x-amzn-trace-id"] = aws}) }
        assert.same({ "aws" }, t)
        assert.spy(warn).was_called_with("invalid aws header trace id; ignoring.")

        aws = fmt("Root=1-%s-vv;Parent=%s;Sampled=%s", string.sub(trace_id_32, 1, 8), span_id, "0")
        t = { parse({["x-amzn-trace-id"] = aws}) }
        assert.same({ "aws" }, t)
        assert.spy(warn).was_called_with("invalid aws header trace id; ignoring.")

        aws = fmt("Root=1-%s-%s;Parent=%s;Sampled=%s", string.sub(too_long_id, 1, 8), string.sub(too_long_id, 9, #too_long_id), big_span_id, "0")
        t = { parse({["x-amzn-trace-id"] = aws}) }
        assert.same({ "aws" }, t)
        assert.spy(warn).was_called_with("invalid aws header trace id; ignoring.")

        aws = fmt("Root=1-%s-%s;Parent=%s;Sampled=%s", string.sub(too_short_id, 1, 1), string.sub(too_short_id, 2, #too_short_id), big_span_id, "0")
        t = { parse({["x-amzn-trace-id"] = aws}) }
        assert.same({ "aws" }, t)
        assert.spy(warn).was_called_with("invalid aws header trace id; ignoring.")

        aws = fmt("Root=;Parent=%s;Sampled=%s", big_span_id, "0")
        t = { parse({["x-amzn-trace-id"] = aws}) }
        assert.same({ "aws" }, t)
        assert.spy(warn).was_called_with("invalid aws header trace id; ignoring.")
      end)

      it("rejects invalid parent IDs", function()
        local aws = fmt("Root=1-%s-%s;Parent=vv;Sampled=%s", string.sub(trace_id_32, 1, 8), string.sub(trace_id_32, 9, #trace_id_32), "0")
        local t = { parse({["x-amzn-trace-id"] = aws}) }
        assert.same({ "aws" }, t)
        assert.spy(warn).was_called_with("invalid aws header parent id; ignoring.")

        aws = fmt("Root=1-%s-%s;Parent=%s;Sampled=%s", string.sub(trace_id_32, 1, 8), string.sub(trace_id_32, 9, #trace_id_32), too_long_id, "0")
        t = { parse({["x-amzn-trace-id"] = aws}) }
        assert.same({ "aws" }, t)
        assert.spy(warn).was_called_with("invalid aws header parent id; ignoring.")

        aws = fmt("Root=1-%s-%s;Parent=%s;Sampled=%s", string.sub(trace_id_32, 1, 8), string.sub(trace_id_32, 2, #trace_id_32), too_short_id, "0")
        t = { parse({["x-amzn-trace-id"] = aws}) }
        assert.same({ "aws" }, t)
        assert.spy(warn).was_called_with("invalid aws header parent id; ignoring.")

        aws = fmt("Root=1-%s-%s;Parent=;Sampled=%s", string.sub(trace_id_32, 1, 8), string.sub(trace_id_32, 2, #trace_id_32), "0")
        t = { parse({["x-amzn-trace-id"] = aws}) }
        assert.same({ "aws" }, t)
        assert.spy(warn).was_called_with("invalid aws header parent id; ignoring.")
      end)

      it("rejects invalid sample flag", function()
        local aws = fmt("Root=1-%s-%s;Parent=%s;Sampled=2", string.sub(trace_id_32, 1, 8), string.sub(trace_id_32, 9, #trace_id_32), span_id)
        local t = { parse({["x-amzn-trace-id"] = aws}) }
        assert.same({ "aws" }, t)
        assert.spy(warn).was_called_with("invalid aws header sampled flag; ignoring.")

        aws = fmt("Root=1-%s-%s;Parent=%s;Sampled=", string.sub(trace_id_32, 1, 8), string.sub(trace_id_32, 9, #trace_id_32), span_id)
        t = { parse({["x-amzn-trace-id"] = aws}) }
        assert.same({ "aws" }, t)
        assert.spy(warn).was_called_with("invalid aws header sampled flag; ignoring.")
      end)
    end)
  end)

  describe("GCP header parsing", function()
    local warn
    setup(function()
      warn = spy.on(kong.log, "warn")
    end)
    before_each(function()
      warn:clear()
    end)
    teardown(function()
      warn:revert()
    end)

    it("valid header with sampling", function()
      local cloud_trace_context = fmt("%s/%s;o=1", trace_id_32, span_id)
      local t = { parse({ ["x-cloud-trace-context"] = cloud_trace_context }) }
      assert.same(
        { "gcp", trace_id_32, tostring(tonumber(span_id)), nil, true },
        { t[1], to_hex(t[2]), openssl_bignumber.from_binary(t[3]):to_dec(), t[4], t[5] }
      )
      assert.spy(warn).not_called()
    end)

    it("valid header without sampling", function()
      local cloud_trace_context = fmt("%s/%s;o=0", trace_id_32, span_id)
      local t = { parse({ ["x-cloud-trace-context"] = cloud_trace_context }) }
      assert.same(
        { "gcp", trace_id_32, tostring(tonumber(span_id)), nil, false },
        { t[1], to_hex(t[2]), openssl_bignumber.from_binary(t[3]):to_dec(), t[4], t[5] }
      )
      assert.spy(warn).not_called()
    end)

    it("valid header without trace flag", function()
      local cloud_trace_context = fmt("%s/%s", trace_id_32, span_id)
      local t = { parse({ ["x-cloud-trace-context"] = cloud_trace_context }) }
      assert.same(
        { "gcp", trace_id_32, tostring(tonumber(span_id)), nil, false },
        { t[1], to_hex(t[2]), openssl_bignumber.from_binary(t[3]):to_dec(), t[4], t[5] }
      )
      assert.spy(warn).not_called()
    end)

    describe("errors", function()
      it("rejects invalid trace IDs", function()
        local cloud_trace_context = fmt("%s/%s;o=0", too_short_id, span_id)
        local t = { parse({ ["x-cloud-trace-context"] = cloud_trace_context }) }
        assert.same({ "gcp" }, t)
        assert.spy(warn).was_called_with("invalid GCP header; ignoring.")

        cloud_trace_context = fmt("%s/%s;o=0", too_long_id, span_id)
        t = { parse({ ["x-cloud-trace-context"] = cloud_trace_context }) }
        assert.same({ "gcp" }, t)
        assert.spy(warn).was_called_with("invalid GCP header; ignoring.")

        -- non hex characters in trace id
        cloud_trace_context = fmt("abcdefghijklmnopqrstuvwxyz123456/%s;o=0", span_id)
        t = { parse({ ["x-cloud-trace-context"] = cloud_trace_context }) }
        assert.same({ "gcp" }, t)
        assert.spy(warn).was_called_with("invalid GCP header; ignoring.")
      end)

      it("rejects invalid span IDs", function()
        -- missing
        local cloud_trace_context = fmt("%s/;o=0", trace_id_32)
        local t = { parse({ ["x-cloud-trace-context"] = cloud_trace_context }) }
        assert.same({ "gcp" }, t)
        assert.spy(warn).was_called_with("invalid GCP header; ignoring.")

        -- decimal value too large
        cloud_trace_context = fmt("%s/%s;o=0", trace_id_32, too_long_id)
        t = { parse({ ["x-cloud-trace-context"] = cloud_trace_context }) }
        assert.same({ "gcp" }, t)
        assert.spy(warn).was_called_with("invalid GCP header; ignoring.")

        -- non digit characters in span id
        cloud_trace_context = fmt("%s/abcdefg;o=0", trace_id_32)
        t = { parse({ ["x-cloud-trace-context"] = cloud_trace_context }) }
        assert.same({ "gcp" }, t)
        assert.spy(warn).was_called_with("invalid GCP header; ignoring.")
      end)

      it("rejects invalid sampling value", function()
        local cloud_trace_context = fmt("%s/%s;o=01", trace_id_32, span_id)
        local t = { parse({ ["x-cloud-trace-context"] = cloud_trace_context }) }
        assert.same({ "gcp" }, t)
        assert.spy(warn).was_called_with("invalid GCP header; ignoring.")

        cloud_trace_context = fmt("%s/%s;o=", trace_id_32, span_id)
        t = { parse({ ["x-cloud-trace-context"] = cloud_trace_context }) }
        assert.same({ "gcp" }, t)
        assert.spy(warn).was_called_with("invalid GCP header; ignoring.")

        cloud_trace_context = fmt("%s/%s;o=v", trace_id_32, span_id)
        t = { parse({ ["x-cloud-trace-context"] = cloud_trace_context }) }
        assert.same({ "gcp" }, t)
        assert.spy(warn).was_called_with("invalid GCP header; ignoring.")
      end)

      it("reports all invalid header values", function()
        local cloud_trace_context = "vvvv/vvvv;o=v"
        local t = { parse({ ["x-cloud-trace-context"] = cloud_trace_context }) }
        assert.same({ "gcp" }, t)
        assert.spy(warn).was_called_with("invalid GCP header; ignoring.")
      end)
    end)
  end)
end)


describe("propagation.set", function()
  local nop = function() end

  local headers
  local warnings

  _G.kong = {
    service = {
      request = {
        set_header = function(name, value)
          headers[name] = value
        end,
      },
    },
    request = {
      get_header = nop,
    },
    log = {
      warn = function(msg)
        warnings[#warnings + 1] = msg
      end
    }
  }

  for k, ids in ipairs({ {trace_id, span_id, parent_id},
                         {big_trace_id, big_span_id, big_parent_id},
                         {trace_id_32, span_id, parent_id},
                         {big_trace_id_32, big_span_id, big_parent_id}, }) do
    local trace_id = ids[1]
    local span_id = ids[2]
    local parent_id = ids[3]

    local w3c_trace_id = to_id_len(trace_id, 32)
    local ot_trace_id = to_id_len(trace_id, 32)
    local gcp_trace_id = to_id_len(trace_id, 32)

    local proxy_span = {
      trace_id = from_hex(trace_id),
      span_id = from_hex(span_id),
      parent_id = from_hex(parent_id),
      should_sample = true,
      each_baggage_item = function() return nop end,
    }

    local b3_headers = {
      ["x-b3-traceid"] = trace_id,
      ["x-b3-spanid"] = span_id,
      ["x-b3-parentspanid"] = parent_id,
      ["x-b3-sampled"] = "1"
    }

    local b3_single_headers = {
      b3 = fmt("%s-%s-1-%s", trace_id, span_id, parent_id)
    }

    local w3c_headers = {
      traceparent = fmt("00-%s-%s-01", w3c_trace_id, span_id)
    }

    local jaeger_headers = {
      ["uber-trace-id"] = fmt("%s:%s:%s:%s", trace_id, span_id, parent_id, "01")
    }

    local ot_headers = {
      ["ot-tracer-traceid"] = ot_trace_id,
      ["ot-tracer-spanid"] = span_id,
      ["ot-tracer-sampled"] = "1"
    }

    local aws_headers = {
      ["x-amzn-trace-id"] = fmt("Root=1-%s-%s;Parent=%s;Sampled=%s",
        string.sub(trace_id, 1, 8),
        string.sub(trace_id, 9, #trace_id),
        span_id,
        "1"
      )
    }

    -- hex values are not valid span id inputs, translate to decimal
    local gcp_headers = {["x-cloud-trace-context"] = gcp_trace_id .. "/" .. openssl_bignumber.from_hex(span_id):to_dec() .. ";o=1"}

    before_each(function()
      headers = {}
      warnings = {}
    end)

    describe("conf.header_type = 'preserve', ids group #" .. k, function()
      it("sets headers according to their found state when conf.header_type = preserve", function()
        set("preserve", "b3", proxy_span)
        assert.same(b3_headers, headers)

        headers = {}

        set("preserve", "b3-single", proxy_span)
        assert.same(b3_single_headers, headers)

        headers = {}

        set("preserve", "w3c", proxy_span)
        assert.same(w3c_headers, headers)

        headers = {}

        set("preserve", "jaeger", proxy_span)
        assert.same(jaeger_headers, headers)

        headers = {}

        set("preserve", "aws", proxy_span)
        assert.same(aws_headers, headers)

        headers = {}

        set("preserve", "gcp", proxy_span)
        assert.same(gcp_headers, headers)

        assert.same({}, warnings)
      end)

      it("sets headers according to default_header_type when no headers are provided", function()
        set("preserve", nil, proxy_span)
        assert.same(b3_headers, headers)

        headers = {}

        set("preserve", nil, proxy_span, "b3")
        assert.same(b3_headers, headers)

        headers = {}

        set("preserve", nil, proxy_span, "b3-single")
        assert.same(b3_single_headers, headers)

        headers = {}

        set("preserve", "w3c", proxy_span, "w3c")
        assert.same(w3c_headers, headers)

        headers = {}

        set("preserve", nil, proxy_span, "jaeger")
        assert.same(jaeger_headers, headers)

        headers = {}

        set("preserve", "ot", proxy_span, "ot")
        assert.same(ot_headers, headers)

        headers = {}

        set("preserve", "aws", proxy_span, "aws")
        assert.same(aws_headers, headers)

        headers = {}
        set("preserve", "gcp", proxy_span, "gcp")
        assert.same(gcp_headers, headers)
      end)
    end)

    describe("conf.header_type = 'b3', ids group #" .. k, function()
      it("sets headers to b3 when conf.header_type = b3", function()
        set("b3", "b3", proxy_span)
        assert.same(b3_headers, headers)

        headers = {}

        set("b3", nil, proxy_span)
        assert.same(b3_headers, headers)

        assert.same({}, warnings)
      end)

      it("sets both the b3 and b3-single headers when a b3-single header is encountered.", function()
        set("b3", "b3-single", proxy_span)
        assert.same(table_merge(b3_headers, b3_single_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the b3 and w3c headers when a w3c header is encountered.", function()
        set("b3", "w3c", proxy_span)
        assert.same(table_merge(b3_headers, w3c_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the b3 and w3c headers when a jaeger header is encountered.", function()
        set("b3", "jaeger", proxy_span)
        assert.same(table_merge(b3_headers, jaeger_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the b3 and gcp headers when a gcp header is encountered.", function()
        set("b3", "gcp", proxy_span)
        assert.same(table_merge(b3_headers, gcp_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)
    end)

    describe("conf.header_type = 'b3-single', ids group #", function()
      it("sets headers to b3-single when conf.header_type = b3-single", function()
        set("b3-single", "b3-single", proxy_span)
        assert.same(b3_single_headers, headers)
        assert.same({}, warnings)
      end)

      it("sets both the b3 and b3-single headers when a b3 header is encountered.", function()
        set("b3-single", "b3", proxy_span)
        assert.same(table_merge(b3_headers, b3_single_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the b3 and w3c headers when a jaeger header is encountered.", function()
        set("b3-single", "w3c", proxy_span)
        assert.same(table_merge(b3_single_headers, w3c_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the b3 and w3c headers when a w3c header is encountered.", function()
        set("b3-single", "jaeger", proxy_span)
        assert.same(table_merge(b3_single_headers, jaeger_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the b3 and gcp headers when a gcp header is encountered.", function()
        set("b3-single", "gcp", proxy_span)
        assert.same(table_merge(b3_single_headers, gcp_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)
    end)

    describe("conf.header_type = 'w3c', ids group #", function()
      it("sets headers to w3c when conf.header_type = w3c", function()
        set("w3c", "w3c", proxy_span)
        assert.same(w3c_headers, headers)
        assert.same({}, warnings)
      end)

      it("sets both the b3 and w3c headers when a b3 header is encountered.", function()
        set("w3c", "b3", proxy_span)
        assert.same(table_merge(b3_headers, w3c_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the b3-single and w3c headers when a b3-single header is encountered.", function()
        set("w3c", "b3-single", proxy_span)
        assert.same(table_merge(b3_single_headers, w3c_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the jaeger and w3c headers when a jaeger header is encountered.", function()
        set("w3c", "jaeger", proxy_span)
        assert.same(table_merge(jaeger_headers, w3c_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the gcp and w3c headers when a gcp header is encountered.", function()
        set("w3c", "gcp", proxy_span)
        assert.same(table_merge(gcp_headers, w3c_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)
    end)

    describe("conf.header_type = 'jaeger', ids group #", function()
      it("sets headers to jaeger when conf.header_type = jaeger", function()
        set("jaeger", "jaeger", proxy_span)
        assert.same(jaeger_headers, headers)
        assert.same({}, warnings)
      end)

      it("sets both the b3 and jaeger headers when a b3 header is encountered.", function()
        set("jaeger", "b3", proxy_span)
        assert.same(table_merge(b3_headers, jaeger_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the b3-single and jaeger headers when a b3-single header is encountered.", function()
        set("jaeger", "b3-single", proxy_span)
        assert.same(table_merge(b3_single_headers, jaeger_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the jaeger and w3c headers when a w3c header is encountered.", function()
        set("jaeger", "w3c", proxy_span)
        assert.same(table_merge(jaeger_headers, w3c_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the jaeger and ot headers when a ot header is encountered.", function()
        set("jaeger", "ot", proxy_span)
        assert.same(table_merge(jaeger_headers, ot_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the jaeger and aws headers when an aws header is encountered.", function()
        set("jaeger", "aws", proxy_span)
        assert.same(table_merge(jaeger_headers, aws_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the jaeger and gcp headers when a gcp header is encountered.", function()
        set("jaeger", "gcp", proxy_span)
        assert.same(table_merge(jaeger_headers, gcp_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)
    end)

    describe("conf.header_type = 'ot', ids group #", function()
      it("sets headers to ot when conf.header_type = ot", function()
        set("ot", "ot", proxy_span)
        assert.same(ot_headers, headers)
        assert.same({}, warnings)
      end)

      it("sets both the b3 and ot headers when a b3 header is encountered.", function()
        set("ot", "b3", proxy_span)
        assert.same(table_merge(b3_headers, ot_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the b3-single and ot headers when a b3-single header is encountered.", function()
        set("ot", "b3-single", proxy_span)
        assert.same(table_merge(b3_single_headers, ot_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the w3c and ot headers when a w3c header is encountered.", function()
        set("ot", "w3c", proxy_span)
        assert.same(table_merge(w3c_headers, ot_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the ot and jaeger headers when a jaeger header is encountered.", function()
        set("ot", "jaeger", proxy_span)
        assert.same(table_merge(ot_headers, jaeger_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the ot and aws headers when a aws header is encountered.", function()
        set("ot", "aws", proxy_span)
        assert.same(table_merge(ot_headers, aws_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the ot and gcp headers when a gcp header is encountered.", function()
        set("ot", "gcp", proxy_span)
        assert.same(table_merge(ot_headers, gcp_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)
    end)

    describe("conf.header_type = 'aws', ids group #", function()
      it("sets headers to ot when conf.header_type = aws", function()
        set("aws", "aws", proxy_span)
        assert.same(aws_headers, headers)
        assert.same({}, warnings)
      end)

      it("sets both the b3 and aws headers when a b3 header is encountered.", function()
        set("aws", "b3", proxy_span)
        assert.same(table_merge(b3_headers, aws_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the b3-single and aws headers when a b3-single header is encountered.", function()
        set("aws", "b3-single", proxy_span)
        assert.same(table_merge(b3_single_headers, aws_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the w3c and aws headers when a w3c header is encountered.", function()
        set("aws", "w3c", proxy_span)
        assert.same(table_merge(w3c_headers, aws_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the aws and jaeger headers when a jaeger header is encountered.", function()
        set("aws", "jaeger", proxy_span)
        assert.same(table_merge(aws_headers, jaeger_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the aws and gcp headers when a gcp header is encountered.", function()
        set("aws", "gcp", proxy_span)
        assert.same(table_merge(aws_headers, gcp_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)
    end)

    describe("conf.header_type = 'gcp', ids group #", function()
      it("sets headers to gcp when conf.header_type = gcp", function()
        set("gcp", "gcp", proxy_span)
        assert.same(gcp_headers, headers)
        assert.same({}, warnings)
      end)

      it("sets both the b3 and gcp headers when a b3 header is encountered.", function()
        set("gcp", "b3", proxy_span)
        assert.same(table_merge(b3_headers, gcp_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the b3-single and gcp headers when a b3-single header is encountered.", function()
        set("gcp", "b3-single", proxy_span)
        assert.same(table_merge(b3_single_headers, gcp_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the gcp and ot headers when a ot header is encountered.", function()
        set("gcp", "ot", proxy_span)
        assert.same(table_merge(gcp_headers, ot_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the w3c and gcp headers when a w3c header is encountered.", function()
        set("gcp", "w3c", proxy_span)
        assert.same(table_merge(w3c_headers, gcp_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the gcp and jaeger headers when a jaeger header is encountered.", function()
        set("gcp", "jaeger", proxy_span)
        assert.same(table_merge(gcp_headers, jaeger_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)

      it("sets both the gcp and aws headers when an aws header is encountered.", function()
        set("gcp", "aws", proxy_span)
        assert.same(table_merge(gcp_headers, aws_headers), headers)

        -- but it generates a warning
        assert.equals(1, #warnings)
        assert.matches("Mismatched header types", warnings[1])
      end)
    end)
  end
end)
