const std = @import("std");

pub fn main() !void {
    std.debug.print("Starting ZIG MQTT client...\n", .{});
    const address = try std.net.Address.resolveIp("127.0.0.1", 1883);
    const stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();

    std.debug.print("Connected to mosquitto broker!\n", .{});

    try sendConnect(stream, "zig-client-01");
    try readConnack(stream);
    try sendPublish(stream, "zig/test", "zig can speak MQTT"); 
    try sendSubscribe(stream, "zig/test");
    try readLoop(stream);
}


fn sendConnect(stream: std.net.Stream, client_id: []const u8) !void {
    //CONNECT
    //┌────────┬──────────┬──────────┬──────────────────────────────────┐
    //│ 0x10   │  Length  │  "MQTT"  │ Protocol Level (4) | Flags | ... │
    //│ type   │          │  + len   │ KeepAlive | ClientID             │
    //└────────┴──────────┴──────────┴──────────────────────────────────┘ 

    var buffer: [256]u8 = undefined;
    var i: u8 = 0;

    // -- Variable header --
    // Protocol name + len
    buffer[i] = 0x00; i += 1;
    buffer[i] = 0x04; i += 1; 
    buffer[i] = 'M'; i += 1;
    buffer[i] = 'Q'; i += 1;
    buffer[i] = 'T'; i += 1;
    buffer[i] = 'T'; i += 1;
    buffer[i] = 4; i += 1; // protocol level -> mqtt 3.1.1

    
    buffer[i] = 0x02; i += 1; // Connect flags: only CleanSession bit set
    buffer[i] = 0x00; i += 1; // Keep alive: 60 seconds
    buffer[i] = 0x3C; i += 1; // Keep alive: 60 seconds
    
    // -- Payload --
    
    buffer[i] = 0x00; i += 1; // Client identifier len
    buffer[i] = @intCast(client_id.len); i += 1; // Client identifier len
    @memcpy(buffer[i..][0..client_id.len], client_id); i += @intCast(client_id.len); // Client identifier 

    // fixed header has type 0x10, len is val of i
    const fixed_header = [_]u8{ 0x10, i };

    _ = try stream.write(&fixed_header);
    _ = try stream.write(buffer[0..i]);

    std.debug.print("CONNECT: was sent!\n", .{});

}

fn readConnack(stream: std.net.Stream) !void {
    // CONNACK (you receive this)
    // ┌────────┬──────────┬──────────┬──────────┐
    // │ 0x20   │  0x02    │  Flags   │ RetCode  │
    // │ type   │  length  │          │ 0x00=OK  │
    // └────────┴──────────┴──────────┴──────────┘
   
    var buf: [4]u8 = undefined;
    _ = try stream.readAtLeast(&buf, 4);

    // check type is correct
    if (buf[0] != 0x20) {
        std.debug.print("Unexpected packet type: {x}\n", .{buf[0]});
        return;
    }

    // check if RetCode=OK
    if (buf[3] == 0x00) {
        std.debug.print("CONNACK: connected successfully!\n", .{});
    } else {
        std.debug.print("CONNACK: refused, code {x}\n", .{buf[3]});
    }
}

fn sendPublish(stream: std.net.Stream, topic: []const u8, payload: []const u8) !void {
    // PUBLISH
    // ┌────────┬──────────┬──────────────────┬─────────┐
    // │ 0x30   │  Length  │  Topic (+ len)   │ Payload │
    // │ type   │          │                  │         │
    // └────────┴──────────┴──────────────────┴─────────┘
    
    var buf: [256]u8 = undefined;
    var i: u8 = 0;

    buf[i] = @intCast(topic.len >> 8); i += 1;  // high byte
    buf[i] = @intCast(topic.len & 0xFF); i += 1; // low byte
    @memcpy(buf[i..][0..topic.len], topic); i += @intCast(topic.len);
    @memcpy(buf[i..][0..payload.len], payload); i += @intCast(payload.len);

    const fixed_header = [_]u8{ 0x30, i};

    _ = try stream.write(&fixed_header);
    _ = try stream.write(buf[0..i]);

    std.debug.print("PUBLISH: published '{s}' on topic '{s}'!\n", .{ payload, topic });
}

fn sendSubscribe(stream: std.net.Stream, topic: []const u8) !void {
    // SUBSCRIBE
    // |---Fixed-----------|---Varible-------------------------------|
    // ┌────────┬──────────┬──────────────┬──────────────────┬───────┐
    // │ 0x82   │  Length  │  Packet ID   │  Topic (+ len)   │  QoS  │
    // │ type   │          │  (2 bytes)   │                  │       │
    // └────────┴──────────┴──────────────┴──────────────────┴───────┘

    var buf: [256]u8 = undefined;
    var i: u8 = 0;
    
    // packet id
    buf[i] = 0x00; i += 1;
    buf[i] = 0x01; i += 1;

    // topic + len
    buf[i] = @intCast(topic.len >> 8); i += 1;  // high byte
    buf[i] = @intCast(topic.len & 0xFF); i += 1; // low byte
    @memcpy(buf[i..][0..topic.len], topic); i += @intCast(topic.len);

    //QoS 0
    buf[i] = 0x00; i+= 1;

    // fixed header
    const fixed_header = [_]u8{ 0x82, i};

    _ = try stream.write(&fixed_header);
    _ = try stream.write(buf[0..i]);

    std.debug.print("SUBSCRIBE: subscribed on topic '{s}'!\n", .{ topic });
} 

fn readLoop(stream: std.net.Stream) !void {
    var read_buf: [256]u8 = undefined;
    var reader = stream.reader(&read_buf);

    std.debug.print("SUBSCRIBE: waiting for messages!\n", .{});

    while (true) {
        var header: [2]u8 = undefined;
        _ = try reader.readAll(&header);

        const packet_type = header[0];
        const len = header[1];

        // read rest of line
        var payload: [256]u8 = undefined;
        _ = try reader.readAll(payload[0..len]);

        switch (packet_type) {
            0x90 => std.debug.print("Recieved SUBACK!\n", .{}),
            0x30 => {
                const topic_len: usize = (@as(usize, payload[0] << 8) | payload[2]); // high and low byte -> shift to combine
                const topic = payload[2..2 + topic_len];
                const message = payload[2 + topic_len..len];
                std.debug.print("PUBLISH recieved on topic '{s}' with message '{s}'.\n", .{ topic, message });

            },
            0xD0 => std.debug.print("Recieved PINGRESP!\n", .{}),
            else => std.debug.print("Unknown packet: {x}\n", .{packet_type}),
        }
    }
}
