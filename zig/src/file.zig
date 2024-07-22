name: []const u8,
description: []const u8,
byte_code: []const u8,
initial_memory: []const u8,
labels: Labels,

pub const Labels = struct {
    labels: []LabelAndOffset,

    pub fn init() Labels {
        return .{ .labels = &[_]LabelAndOffset{} };
    }

    pub fn find_for_offset(labels: Labels, offset: usize) ?[]const u8 {
        var i = labels.labels.len;
        while (i > 0) {
            i -= 1;
            const label = labels.labels[i];
            if (label.offset <= offset) return label.label;
        }
        return null;
    }
};

pub const LabelAndOffset = struct { label: []const u8, offset: usize };
