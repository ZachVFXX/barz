const std = @import("std");
const builtin = @import("builtin");
const pw = @import("pipewire").c;

const Self = @This();
const endian = builtin.cpu.arch.endian();

pub const interval = 1;

pub const Level = struct {
    present: bool = false, // false until the device reported its volume
    percent: u16 = 0,
    muted: bool = false,
    in_use: bool = false, // playing/recording
};
pub const Data = struct { speaker: Level, micro: Level };

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
    // from the node state (streams)
    running: bool = false,
};

const Device = struct {
    active: bool = false,
    id: u32 = 0,
    proxy: ?*pw.pw_proxy = null,
    hook: pw.spa_hook = std.mem.zeroes(pw.spa_hook),
    mute: [2]bool = .{ false, false }, // [0] = input, [1] = output
    vol: [2]?f32 = .{ null, null },
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
            if (vol == null) vol = d.vol[i];
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

/// When an object's info says its params changed, ask for the new values
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

// {"name":"alsa_output.pci-0000_00_1f.3.analog-stereo"}  ->  the name
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
    if (r.volume) |v| {
        node.volume = v;
        node.have = true;
    }
}

/// Route param: {direction, ..., props = { mute, channelVolumes, ... }}
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

    while (off + 16 <= end) {
        const key = rd32(base, off);
        const vsize: usize = rd32(base, off + 8);
        const vtype = rd32(base, off + 12);
        const body = off + 16;

        if (key == pw.SPA_PARAM_ROUTE_direction and vtype == pw.SPA_TYPE_Id) {
            direction = rd32(base, body);
        } else if (key == pw.SPA_PARAM_ROUTE_props and vtype == pw.SPA_TYPE_Object) {
            props = scanProps(base, body + 8, body + vsize); // skip the object body header
        }
        off += 16 + ((vsize + 7) & ~@as(usize, 7));
    }

    const dir = direction orelse return;
    const r = props orelse return;
    const i: usize = if (dir == 0) 0 else 1; // 0 = input (mic), 1 = output
    if (r.saw_mute) dev.mute[i] = r.muted;
    if (r.volume) |v| dev.vol[i] = v;
}

gpa: std.mem.Allocator,
st: *State,
cached_data: ?Data = null,

pub fn init(_: std.Io, gpa: std.mem.Allocator) !Self {
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
    return .{ .gpa = gpa, .st = st };
}

pub fn deinit(self: *Self, _: std.Io) void {
    pw.pw_thread_loop_stop(self.st.tloop);
    _ = pw.pw_core_disconnect(self.st.core);
    pw.pw_context_destroy(self.st.context);
    pw.pw_thread_loop_destroy(self.st.tloop);
    pw.pw_deinit();
    self.gpa.destroy(self.st);
}

/// PipeWire pushes changes this only copies the latest state
pub fn poll(self: *Self, _: std.Io, _: u64) ?Data {
    pw.pw_thread_loop_lock(self.st.tloop);
    defer pw.pw_thread_loop_unlock(self.st.tloop);
    const st = self.st;
    self.cached_data = .{
        .speaker = st.level(.sink, st.anyRunning(.playing)),
        .micro = st.level(.source, st.anyRunning(.recording)),
    };
    return self.cached_data;
}
