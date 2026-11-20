const std = @import("std");
const builtin = @import("builtin");
const pw = @import("pipewire").c;

const Self = @This();

const endian = builtin.cpu.arch.endian();

const max_percent = 100;
const max_channels = 16;

pub const Level = struct {
    present: bool = false, // false until the device reported its volume
    percent: u16 = 0,
    muted: bool = false,
    in_use: bool = false, // playing/recording
};
pub const Data = struct { speaker: Level, micro: Level };

pub const Target = enum { speaker, micro };

const Kind = enum { sink, source, playing, recording };

const Name = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,
    fn set(self: *Name, s: []const u8) void {
        const n = @min(s.len, self.buf.len);
        @memcpy(self.buf[0..n], s[0..n]);
        self.len = n;
    }
    fn get(self: *const Name) []const u8 {
        return self.buf[0..self.len];
    }
};

const no_device = std.math.maxInt(u32);

const Node = struct {
    active: bool = false,
    id: u32 = 0,
    kind: Kind = .sink,
    name: Name = .{},
    device_id: u32 = no_device, // the ALSA/bluez device this node belongs to
    proxy: ?*pw.pw_proxy = null,
    hook: pw.spa_hook = std.mem.zeroes(pw.spa_hook),
    // from the node Props
    have: bool = false,
    volume: f32 = 0, // linear
    mute_node: bool = false,
    channels: u32 = 0, // from the last channelVolumes param
    // from the node state
    running: bool = false,
};

const Device = struct {
    active: bool = false,
    id: u32 = 0,
    proxy: ?*pw.pw_proxy = null,
    hook: pw.spa_hook = std.mem.zeroes(pw.spa_hook),
    mute: [2]bool = .{ false, false }, // [0] = input, [1] = output
    vol: [2]?f32 = .{ null, null },

    route_index: [2]u32 = .{ 0, 0 },
    route_device: [2]u32 = .{ 0, 0 },
    channels: [2]u32 = .{ 0, 0 },
};

const State = struct {
    tloop: *pw.pw_thread_loop = undefined,
    context: *pw.pw_context = undefined,
    core: *pw.pw_core = undefined,
    registry: *pw.pw_registry = undefined,
    reg_hook: pw.spa_hook = std.mem.zeroes(pw.spa_hook),
    meta: ?*pw.pw_proxy = null,
    meta_hook: pw.spa_hook = std.mem.zeroes(pw.spa_hook),

    nodes: [48]Node = @splat(Node{}), // devices and streams
    devs: [8]Device = @splat(Device{}),
    default_sink: Name = .{},
    default_source: Name = .{},

    fn pick(self: *State, kind: Kind) ?*Node {
        const want = if (kind == .sink) self.default_sink.get() else self.default_source.get();
        var first: ?*Node = null;
        for (&self.nodes) |*n| {
            if (!n.active or n.kind != kind) continue;
            if (want.len > 0 and std.mem.eql(u8, n.name.get(), want)) return n;
            if (first == null) first = n;
        }
        return first;
    }

    fn findDev(self: *State, id: u32) ?*Device {
        if (id == no_device) return null;
        for (&self.devs) |*d| {
            if (d.active and d.id == id) return d;
        }
        return null;
    }

    fn anyRunning(self: *State, kind: Kind) bool {
        for (&self.nodes) |*n| {
            if (n.active and n.kind == kind and n.running) return true;
        }
        return false;
    }

    fn level(self: *State, kind: Kind, in_use: bool) Level {
        const n = self.pick(kind) orelse return .{};

        var muted = n.mute_node;
        var vol: ?f32 = if (n.have) n.volume else null;
        if (self.findDev(n.device_id)) |d| {
            const i: usize = if (kind == .source) 0 else 1;
            muted = muted or d.mute[i];
            if (d.vol[i]) |dv| vol = dv;
        }

        const v = vol orelse return .{};
        const p = std.math.cbrt(@max(v, 0)) * 100;
        return .{
            .present = true,
            .percent = @intFromFloat(@round(@min(p, 1000))),
            .muted = muted,
            .in_use = in_use,
        };
    }
};

fn vt(comptime M: type, obj: anytype) struct { m: *const M, d: ?*anyopaque } {
    const iface: *pw.spa_interface = @ptrCast(@alignCast(obj));
    return .{ .m = @ptrCast(@alignCast(iface.cb.funcs.?)), .d = iface.cb.data };
}

fn coreGetRegistry(core: *pw.pw_core, version: u32) ?*pw.pw_registry {
    const v = vt(pw.pw_core_methods, core);
    return v.m.get_registry.?(v.d, version, 0);
}

fn registryBind(st: *State, id: u32, typ: [*:0]const u8, version: u32) ?*anyopaque {
    const v = vt(pw.pw_registry_methods, st.registry);
    return v.m.bind.?(v.d, id, typ, version, 0);
}

fn dictGet(d: *const pw.spa_dict, key: []const u8) ?[]const u8 {
    var i: u32 = 0;
    while (i < d.n_items) : (i += 1) {
        const it = d.items[i];
        if (it.key == null or it.value == null) continue;
        if (std.mem.eql(u8, std.mem.span(it.key), key)) return std.mem.span(it.value);
    }
    return null;
}

fn isTrue(d: *const pw.spa_dict, key: []const u8) bool {
    return if (dictGet(d, key)) |v| std.mem.eql(u8, v, "true") else false;
}
fn reenum(comptime M: type, proxy: *pw.pw_proxy, params: [*c]const pw.spa_param_info, n: u32, want: u32) void {
    if (params == null) return;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const p = params[i];
        if (p.id == want and (p.flags & pw.SPA_PARAM_INFO_READ) != 0) {
            const v = vt(M, proxy);
            _ = v.m.enum_params.?(v.d, 1, want, 0, std.math.maxInt(u32), null);
        }
    }
}

const registry_events: pw.pw_registry_events = .{
    .version = 0,
    .global = registryGlobal,
    .global_remove = registryGlobalRemove,
};
const node_events: pw.pw_node_events = .{ .version = 0, .info = nodeInfo, .param = nodeParam };
const device_events: pw.pw_device_events = .{ .version = 0, .info = devInfo, .param = devParam };
const meta_events: pw.pw_metadata_events = .{ .version = 0, .property = metaProperty };

fn registryGlobal(
    data: ?*anyopaque,
    id: u32,
    _: u32,
    typ: [*c]const u8,
    _: u32,
    props_c: [*c]const pw.spa_dict,
) callconv(.c) void {
    if (props_c == null or typ == null) return;
    const st: *State = @ptrCast(@alignCast(data.?));
    const props: *const pw.spa_dict = props_c;
    const t = std.mem.span(typ);

    if (std.mem.eql(u8, t, "PipeWire:Interface:Node")) {
        const class = dictGet(props, "media.class") orelse return;
        const kind: Kind = if (std.mem.eql(u8, class, "Audio/Sink"))
            .sink
        else if (std.mem.eql(u8, class, "Audio/Source"))
            .source
        else if (std.mem.startsWith(u8, class, "Stream/Output/Audio"))
            .playing
        else if (std.mem.startsWith(u8, class, "Stream/Input/Audio"))
            .recording
        else
            return;

        // ignore volume meters / monitor captures
        if (kind == .playing or kind == .recording) {
            if (isTrue(props, "stream.monitor") or isTrue(props, "stream.capture.sink")) return;
        }
        addNode(st, id, kind, props);
    } else if (std.mem.eql(u8, t, "PipeWire:Interface:Device")) {
        const class = dictGet(props, "media.class") orelse return;
        if (std.mem.eql(u8, class, "Audio/Device")) addDev(st, id);
    } else if (std.mem.eql(u8, t, "PipeWire:Interface:Metadata")) {
        const name = dictGet(props, "metadata.name") orelse return;
        if (st.meta == null and std.mem.eql(u8, name, "default")) {
            const raw = registryBind(st, id, "PipeWire:Interface:Metadata", 3) orelse return;
            st.meta = @ptrCast(@alignCast(raw));
            const v = vt(pw.pw_metadata_methods, raw);
            _ = v.m.add_listener.?(v.d, &st.meta_hook, &meta_events, st);
        }
    }
}

fn registryGlobalRemove(data: ?*anyopaque, id: u32) callconv(.c) void {
    const st: *State = @ptrCast(@alignCast(data.?));
    for (&st.nodes) |*n| {
        if (n.active and n.id == id) {
            if (n.proxy) |p| pw.pw_proxy_destroy(p);
            n.active = false;
            n.proxy = null;
        }
    }
    for (&st.devs) |*d| {
        if (d.active and d.id == id) {
            if (d.proxy) |p| pw.pw_proxy_destroy(p);
            d.active = false;
            d.proxy = null;
        }
    }
}

fn addNode(st: *State, id: u32, kind: Kind, props: *const pw.spa_dict) void {
    const slot: *Node = blk: {
        for (&st.nodes) |*n| if (!n.active) break :blk n;
        return; // table full
    };
    const raw = registryBind(st, id, "PipeWire:Interface:Node", 3) orelse return;
    slot.* = .{ .active = true, .id = id, .kind = kind, .proxy = @ptrCast(@alignCast(raw)) };
    slot.name.set(dictGet(props, "node.name") orelse "");
    if (dictGet(props, "device.id")) |s| slot.device_id = std.fmt.parseInt(u32, s, 10) catch no_device;

    const v = vt(pw.pw_node_methods, raw);
    _ = v.m.add_listener.?(v.d, &slot.hook, &node_events, slot);
    if (kind == .sink or kind == .source) { // streams only need their state
        var ids = [_]u32{pw.SPA_PARAM_Props};
        _ = v.m.subscribe_params.?(v.d, &ids, 1);
    }
}

fn addDev(st: *State, id: u32) void {
    const slot: *Device = blk: {
        for (&st.devs) |*d| if (!d.active) break :blk d;
        return;
    };
    const raw = registryBind(st, id, "PipeWire:Interface:Device", 3) orelse return;
    slot.* = .{ .active = true, .id = id, .proxy = @ptrCast(@alignCast(raw)) };

    const v = vt(pw.pw_device_methods, raw);
    _ = v.m.add_listener.?(v.d, &slot.hook, &device_events, slot);
    var ids = [_]u32{pw.SPA_PARAM_Route};
    _ = v.m.subscribe_params.?(v.d, &ids, 1);
}

fn jsonName(s: []const u8) []const u8 {
    const k = std.mem.indexOf(u8, s, "\"name\"") orelse return "";
    const colon = std.mem.indexOfPos(u8, s, k + 6, ":") orelse return "";
    const q1 = std.mem.indexOfPos(u8, s, colon + 1, "\"") orelse return "";
    const q2 = std.mem.indexOfPos(u8, s, q1 + 1, "\"") orelse return "";
    return s[q1 + 1 .. q2];
}

fn metaProperty(
    data: ?*anyopaque,
    _: u32,
    key: [*c]const u8,
    _: [*c]const u8,
    value: [*c]const u8,
) callconv(.c) c_int {
    if (key == null) return 0;
    const st: *State = @ptrCast(@alignCast(data.?));
    const k = std.mem.span(key);
    const target: *Name = if (std.mem.eql(u8, k, "default.audio.sink"))
        &st.default_sink
    else if (std.mem.eql(u8, k, "default.audio.source"))
        &st.default_source
    else
        return 0;
    if (value == null) {
        target.len = 0;
    } else {
        target.set(jsonName(std.mem.span(value)));
    }
    return 0;
}

fn nodeInfo(data: ?*anyopaque, info: [*c]const pw.pw_node_info) callconv(.c) void {
    if (info == null) return;
    const node: *Node = @ptrCast(@alignCast(data.?));
    // the server only fills in what changed so always check the mask
    const mask = info.*.change_mask;

    // PW_NODE_CHANGE_MASK_STATE
    if ((mask & (1 << 2)) != 0) {
        node.running = info.*.state == pw.PW_NODE_STATE_RUNNING;
    }

    // mute/volume may have changed
    if ((mask & (1 << 4)) != 0 and (node.kind == .sink or node.kind == .source)) {
        if (node.proxy) |p| reenum(pw.pw_node_methods, p, info.*.params, info.*.n_params, pw.SPA_PARAM_Props);
    }
}

fn devInfo(data: ?*anyopaque, info: [*c]const pw.pw_device_info) callconv(.c) void {
    if (info == null) return;
    const dev: *Device = @ptrCast(@alignCast(data.?));
    // PW_DEVICE_CHANGE_MASK_PARAMS
    if ((info.*.change_mask & (1 << 1)) != 0) {
        if (dev.proxy) |p| reenum(pw.pw_device_methods, p, info.*.params, info.*.n_params, pw.SPA_PARAM_Route);
    }
}

fn rd32(base: [*]const u8, off: usize) u32 {
    return std.mem.readInt(u32, base[off..][0..4], endian);
}

const PropsRead = struct {
    saw_mute: bool = false,
    muted: bool = false,
    volume: ?f32 = null,
    channels: u32 = 0,
};

/// Scans the properties in base[from..to] for mute and volume
fn scanProps(base: [*]const u8, from: usize, to: usize) PropsRead {
    var r: PropsRead = .{};
    var vol: ?f32 = null;
    var chan: ?f32 = null;
    var off = from;

    while (off + 16 <= to) {
        const key = rd32(base, off);
        const vsize: usize = rd32(base, off + 8);
        const vtype = rd32(base, off + 12);
        const body = off + 16;

        if ((key == pw.SPA_PROP_mute or key == pw.SPA_PROP_softMute) and vtype == pw.SPA_TYPE_Bool) {
            r.saw_mute = true;
            if (rd32(base, body) != 0) r.muted = true;
        } else if (key == pw.SPA_PROP_volume and vtype == pw.SPA_TYPE_Float) {
            vol = @as(f32, @bitCast(rd32(base, body)));
        } else if (key == pw.SPA_PROP_channelVolumes and vtype == pw.SPA_TYPE_Array and vsize >= 8) {
            if (rd32(base, body) == 4) {
                var m: f32 = 0;
                var o = body + 8;
                while (o + 4 <= body + vsize) : (o += 4) {
                    m = @max(m, @as(f32, @bitCast(rd32(base, o))));
                }
                chan = m;
                r.channels = @intCast((vsize - 8) / 4);
            }
        }
        off += 16 + ((vsize + 7) & ~@as(usize, 7));
    }
    r.volume = chan orelse vol;
    return r;
}

fn nodeParam(
    data: ?*anyopaque,
    _: c_int,
    id: u32,
    _: u32,
    _: u32,
    param: [*c]const pw.spa_pod,
) callconv(.c) void {
    if (id != pw.SPA_PARAM_Props or param == null) return;
    const node: *Node = @ptrCast(@alignCast(data.?));
    const base: [*]const u8 = @ptrCast(param);
    if (rd32(base, 4) != pw.SPA_TYPE_Object) return;

    const r = scanProps(base, 16, 8 + @as(usize, rd32(base, 0)));
    if (r.saw_mute) node.mute_node = r.muted;
    if (r.channels > 0) node.channels = r.channels;
    if (r.volume) |v| {
        node.volume = v;
        node.have = true;
    }
}

fn devParam(
    data: ?*anyopaque,
    _: c_int,
    id: u32,
    _: u32,
    _: u32,
    param: [*c]const pw.spa_pod,
) callconv(.c) void {
    if (id != pw.SPA_PARAM_Route or param == null) return;
    const dev: *Device = @ptrCast(@alignCast(data.?));
    const base: [*]const u8 = @ptrCast(param);
    if (rd32(base, 4) != pw.SPA_TYPE_Object) return;

    const end = 8 + @as(usize, rd32(base, 0));
    var off: usize = 16;
    var direction: ?u32 = null;
    var props: ?PropsRead = null;
    var r_index: u32 = 0;
    var r_device: u32 = 0;

    while (off + 16 <= end) {
        const key = rd32(base, off);
        const vsize: usize = rd32(base, off + 8);
        const vtype = rd32(base, off + 12);
        const body = off + 16;

        if (key == pw.SPA_PARAM_ROUTE_direction and vtype == pw.SPA_TYPE_Id) {
            direction = rd32(base, body);
        } else if (key == pw.SPA_PARAM_ROUTE_index and vtype == pw.SPA_TYPE_Int) {
            r_index = rd32(base, body);
        } else if (key == pw.SPA_PARAM_ROUTE_device and vtype == pw.SPA_TYPE_Int) {
            r_device = rd32(base, body);
        } else if (key == pw.SPA_PARAM_ROUTE_props and vtype == pw.SPA_TYPE_Object) {
            props = scanProps(base, body + 8, body + vsize); // skip the object body header
        }
        off += 16 + ((vsize + 7) & ~@as(usize, 7));
    }

    const dir = direction orelse return;
    const r = props orelse return;
    const i: usize = if (dir == 0) 0 else 1;
    if (r.saw_mute) dev.mute[i] = r.muted;
    if (r.volume) |v| dev.vol[i] = v;
    if (r.channels > 0) dev.channels[i] = r.channels;
    dev.route_index[i] = r_index;
    dev.route_device[i] = r_device;
}

fn put(buf: []u8, off: *usize, v: u32) void {
    std.mem.writeInt(u32, buf[off.*..][0..4], v, endian);
    off.* += 4;
}

fn sendProps(node: *Node, buf: *align(8) [256]u8) void {
    const p = node.proxy orelse return;
    const v = vt(pw.pw_node_methods, p);
    _ = v.m.set_param.?(v.d, pw.SPA_PARAM_Props, 0, @ptrCast(buf));
}

fn sendMute(node: *Node, mute: bool) void {
    var buf: [256]u8 align(8) = undefined;
    var o: usize = 0;
    put(&buf, &o, 8 + 24); // body= type + id + one 24 bytes property
    put(&buf, &o, pw.SPA_TYPE_Object);
    put(&buf, &o, pw.SPA_TYPE_OBJECT_Props);
    put(&buf, &o, pw.SPA_PARAM_Props);
    put(&buf, &o, pw.SPA_PROP_mute);
    put(&buf, &o, 0); // flags
    put(&buf, &o, 4); // bool pod size
    put(&buf, &o, pw.SPA_TYPE_Bool);
    put(&buf, &o, @intFromBool(mute));
    put(&buf, &o, 0); // padding to 8
    sendProps(node, &buf);
}

fn sendVolume(node: *Node, linear: f32) void {
    const ch: u32 = if (node.channels == 0) 2 else @min(node.channels, max_channels);
    const arr_body: u32 = 8 + 4 * ch; // child pod header + floats
    const pad: u32 = (8 - arr_body % 8) % 8;
    const prop_len: u32 = 16 + arr_body + pad; // key + flags + pod header + body + pad

    var buf: [256]u8 align(8) = undefined;
    var o: usize = 0;
    put(&buf, &o, 8 + prop_len);
    put(&buf, &o, pw.SPA_TYPE_Object);
    put(&buf, &o, pw.SPA_TYPE_OBJECT_Props);
    put(&buf, &o, pw.SPA_PARAM_Props);
    put(&buf, &o, pw.SPA_PROP_channelVolumes);
    put(&buf, &o, 0); // flags
    put(&buf, &o, arr_body);
    put(&buf, &o, pw.SPA_TYPE_Array);
    put(&buf, &o, 4); // child size
    put(&buf, &o, pw.SPA_TYPE_Float);
    for (0..ch) |_| put(&buf, &o, @bitCast(linear));
    @memset(buf[o..][0..pad], 0);
    sendProps(node, &buf);
}

/// writes mute and/or volume on the device active Route
/// `i` is the direction index: 0 = input, 1 = output.
fn sendRoute(dev: *Device, i: usize, mute: ?bool, linear: ?f32) void {
    const p = dev.proxy orelse return;
    const ch: u32 = if (dev.channels[i] == 0) 2 else @min(dev.channels[i], max_channels);
    const arr_body: u32 = 8 + 4 * ch;
    const pad: u32 = (8 - arr_body % 8) % 8;
    const mute_len: u32 = if (mute != null) 24 else 0;
    const vol_len: u32 = if (linear != null) 16 + arr_body + pad else 0;
    const props_body: u32 = 8 + mute_len + vol_len; // object type + id + properties

    var buf: [512]u8 align(8) = undefined;
    var o: usize = 0;
    // outer body: type + id, index (24), device (24), props (16 + body), save (24)
    put(&buf, &o, 8 + 24 + 24 + (16 + props_body) + 24);
    put(&buf, &o, pw.SPA_TYPE_Object);
    put(&buf, &o, pw.SPA_TYPE_OBJECT_ParamRoute);
    put(&buf, &o, pw.SPA_PARAM_Route);

    // index
    put(&buf, &o, pw.SPA_PARAM_ROUTE_index);
    put(&buf, &o, 0);
    put(&buf, &o, 4);
    put(&buf, &o, pw.SPA_TYPE_Int);
    put(&buf, &o, dev.route_index[i]);
    put(&buf, &o, 0);

    // device
    put(&buf, &o, pw.SPA_PARAM_ROUTE_device);
    put(&buf, &o, 0);
    put(&buf, &o, 4);
    put(&buf, &o, pw.SPA_TYPE_Int);
    put(&buf, &o, dev.route_device[i]);
    put(&buf, &o, 0);

    // props = { mute?, channelVolumes? }
    put(&buf, &o, pw.SPA_PARAM_ROUTE_props);
    put(&buf, &o, 0);
    put(&buf, &o, props_body);
    put(&buf, &o, pw.SPA_TYPE_Object);
    put(&buf, &o, pw.SPA_TYPE_OBJECT_Props);
    put(&buf, &o, pw.SPA_PARAM_Route);
    if (mute) |m| {
        put(&buf, &o, pw.SPA_PROP_mute);
        put(&buf, &o, 0);
        put(&buf, &o, 4);
        put(&buf, &o, pw.SPA_TYPE_Bool);
        put(&buf, &o, @intFromBool(m));
        put(&buf, &o, 0);
    }
    if (linear) |v| {
        put(&buf, &o, pw.SPA_PROP_channelVolumes);
        put(&buf, &o, 0);
        put(&buf, &o, arr_body);
        put(&buf, &o, pw.SPA_TYPE_Array);
        put(&buf, &o, 4);
        put(&buf, &o, pw.SPA_TYPE_Float);
        for (0..ch) |_| put(&buf, &o, @bitCast(v));
        @memset(buf[o..][0..pad], 0);
        o += pad;
    }

    put(&buf, &o, pw.SPA_PARAM_ROUTE_save);
    put(&buf, &o, 0);
    put(&buf, &o, 4);
    put(&buf, &o, pw.SPA_TYPE_Bool);
    put(&buf, &o, 1);
    put(&buf, &o, 0);

    const v = vt(pw.pw_device_methods, p);
    _ = v.m.set_param.?(v.d, pw.SPA_PARAM_Route, 0, @ptrCast(&buf));
}

fn stepLinear(cur_linear: f32, delta: i32) f32 {
    const cur: i32 = @intFromFloat(@round(std.math.cbrt(@max(cur_linear, 0)) * 100));
    const pct: f32 = @floatFromInt(std.math.clamp(cur + delta, 0, max_percent));
    return std.math.pow(f32, pct / 100, 3);
}

gpa: std.mem.Allocator,
st: *State,
interval: std.Io.Duration,

pub fn init(_: std.Io, gpa: std.mem.Allocator, interval: std.Io.Duration) !Self {
    pw.pw_init(null, null);

    const st = try gpa.create(State);
    errdefer gpa.destroy(st);
    st.* = .{};

    st.tloop = pw.pw_thread_loop_new("barz", null) orelse return error.PipeWire;
    errdefer pw.pw_thread_loop_destroy(st.tloop);
    st.context = pw.pw_context_new(pw.pw_thread_loop_get_loop(st.tloop), null, 0) orelse return error.PipeWire;
    errdefer pw.pw_context_destroy(st.context);
    st.core = pw.pw_context_connect(st.context, null, 0) orelse return error.NoPipeWireDaemon;
    errdefer {
        _ = pw.pw_core_disconnect(st.core);
    }

    st.registry = coreGetRegistry(st.core, 3) orelse return error.PipeWire;
    const v = vt(pw.pw_registry_methods, st.registry);
    _ = v.m.add_listener.?(v.d, &st.reg_hook, &registry_events, st);

    if (pw.pw_thread_loop_start(st.tloop) < 0) return error.PipeWire;
    return .{ .gpa = gpa, .st = st, .interval = interval };
}

pub fn deinit(self: *Self, _: std.Io) void {
    pw.pw_thread_loop_stop(self.st.tloop);
    _ = pw.pw_core_disconnect(self.st.core);
    pw.pw_context_destroy(self.st.context);
    pw.pw_thread_loop_destroy(self.st.tloop);
    pw.pw_deinit();
    self.gpa.destroy(self.st);
}

pub fn read(self: *Self, _: std.Io) !Data {
    pw.pw_thread_loop_lock(self.st.tloop);
    defer pw.pw_thread_loop_unlock(self.st.tloop);
    const st = self.st;
    return .{
        .speaker = st.level(.sink, st.anyRunning(.playing)),
        .micro = st.level(.source, st.anyRunning(.recording)),
    };
}

pub fn toggleMute(self: *Self, target: Target) void {
    pw.pw_thread_loop_lock(self.st.tloop);
    defer pw.pw_thread_loop_unlock(self.st.tloop);

    const kind: Kind = if (target == .speaker) .sink else .source;
    const node = self.st.pick(kind) orelse return;
    const i: usize = if (kind == .source) 0 else 1;

    if (self.st.findDev(node.device_id)) |d| {
        if (d.vol[i] != null) { // this device has a hardware route
            const muted = !(d.mute[i] or node.mute_node);
            d.mute[i] = muted;
            sendRoute(d, i, muted, null);
            if (node.mute_node and !muted) { // a stale node mute would keep it silent
                node.mute_node = false;
                sendMute(node, false);
            }
            return;
        }
    }

    node.mute_node = !node.mute_node;
    sendMute(node, node.mute_node);
}

/// `delta` is in percent points (5 / -5)
pub fn adjustVolume(self: *Self, target: Target, delta: i32) void {
    pw.pw_thread_loop_lock(self.st.tloop);
    defer pw.pw_thread_loop_unlock(self.st.tloop);

    const kind: Kind = if (target == .speaker) .sink else .source;
    const node = self.st.pick(kind) orelse return;
    const i: usize = if (kind == .source) 0 else 1;

    if (self.st.findDev(node.device_id)) |d| {
        if (d.vol[i]) |cur| {
            const linear = stepLinear(cur, delta);
            d.vol[i] = linear;
            sendRoute(d, i, null, linear);
            return;
        }
    }

    if (!node.have) return;
    const linear = stepLinear(node.volume, delta);
    node.volume = linear;
    sendVolume(node, linear);
}
