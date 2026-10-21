-- Minimal public Android graphics doubles; the real PNG is checked on a phone.
local json = require "json"
return function(calls)
    calls.frames, calls.encodes, calls.recycles, calls.closes = {}, 0, 0, 0
    local classes = {}
    classes["android.graphics.Bitmap$Config"] = {ARGB_8888 = "argb"}
    classes["android.graphics.Bitmap$CompressFormat"] = {PNG = "png"}
    classes["android.graphics.Paint$Align"] = {LEFT = "left", RIGHT = "right"}
    classes["android.graphics.Typeface"] = {create = function(_, family, style) return family .. style end}
    classes["android.graphics.Bitmap"] = {createBitmap = function(_, width, height, config)
        assert(width > 0 and width < math.huge and width == math.floor(width))
        assert(height > 0 and height < math.huge and height == math.floor(height))
        assert(config == "argb")
        local frame = {width = width, height = height, text = {}, rects = {}}
        calls.frames[#calls.frames + 1] = frame
        return {
            frame = frame,
            compress = function(_, format, quality, stream)
                assert(format == "png" and quality == 100)
                calls.encodes = calls.encodes + 1
                stream.data = json.encode(frame)
                return true
            end,
            recycle = function() calls.recycles = calls.recycles + 1 end,
        }
    end}
    classes["android.graphics.Paint"] = {new = function(flags)
        assert(flags == 3)
        return {
            setTypeface = function() end,
            setARGB = function(self, a, r, g, b)
                assert(a == 255 and r and g and b)
                self.color = string.format("#%02X%02X%02X", r, g, b)
            end,
            setTextSize = function(self, size) self.size = size end,
            setTextAlign = function(self, align) self.align = align end,
        }
    end}
    classes["android.graphics.Canvas"] = {new = function(bitmap)
        local frame = bitmap.frame
        return {
            scale = function(_, x, y) frame.scale = {x, y} end,
            drawText = function(_, value, x, y, paint)
                if calls.fail_png then error("Simulated rendering failure") end
                frame.text[#frame.text + 1] = {value, x, y, paint.size, paint.color, paint.align}
            end,
            drawRoundRect = function(_, x1, y1, x2, y2, rx, ry, paint)
                assert(x2 > x1 and y2 > y1 and rx == 1 and ry == 1)
                frame.rects[#frame.rects + 1] = {x1, y1, x2, y2, paint.color}
            end,
        }
    end}
    classes["java.io.ByteArrayOutputStream"] = {new = function()
        return {toByteArray = function(self) return self.data end,
            close = function() calls.closes = calls.closes + 1 end}
    end}
    classes["android.util.Base64"] = {encodeToString = function(_, data, flags)
        assert(flags == 2)
        return data -- Deterministic stand-in for encoded PNG bytes.
    end}
    local Class = {forName = function(_, name) return assert(classes[name], name) end}
    Class.getClass = function() return Class end
    return Class
end
