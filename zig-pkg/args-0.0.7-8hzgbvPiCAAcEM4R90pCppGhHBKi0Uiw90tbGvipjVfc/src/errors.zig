//! Error types and handling for args.zig.

const std = @import("std");

/// Errors that occur during argument parsing.
pub const ParseError = error{
    UnknownOption,
    MissingRequired,
    MissingValue,
    InvalidValue,
    TooManyValues,
    TooFewValues,
    InvalidChoice,
    ConflictingArguments,
    MissingDependency,
    DuplicateArgument,
    InvalidFormat,
    UnexpectedPositional,
    UnknownSubcommand,
    MissingSubcommand,
    MutuallyExclusive,
    OutOfMemory,
    Overflow,
    InvalidCharacter,
    /// An argument is required because another argument (or its value) is present.
    RequiredIfViolation,
    /// Two arguments that mutually conflict were both provided.
    CircularConflict,
};

/// Errors that occur during schema definition.
pub const SchemaError = error{
    DuplicateArgument,
    InvalidShortName,
    InvalidLongName,
    MissingName,
    EmptyName,
    DuplicateName,
    DuplicateAlias,
    InvalidConfig,
    PositionalAfterVariadic,
    RequiredAfterOptional,
    InvalidNargs,
    InvalidDefault,
    InvalidChoices,
    CircularDependency,
    SelfConflict,
    OutOfMemory,
    /// Argument declared to conflict with itself.
    ConflictingSelf,
    /// Regex pattern could not be compiled.
    InvalidRegex,
    /// Duration format string is malformed.
    InvalidDuration,
};

/// Errors that occur during value validation.
pub const ValidationError = error{
    OutOfRange,
    TooShort,
    TooLong,
    PatternMismatch,
    CustomValidationFailed,
    FileNotFound,
    DirectoryNotFound,
    PermissionDenied,
    InvalidPath,
};

/// Context information for error reporting.
pub const ErrorContext = struct {
    argument: ?[]const u8 = null,
    value: ?[]const u8 = null,
    expected: ?[]const u8 = null,
    position: ?usize = null,
    message: ?[]const u8 = null,
    suggestion: ?[]const u8 = null,

    pub fn format(self: ErrorContext, allocator: std.mem.Allocator) ![]const u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        const writer = &aw.writer;

        if (self.argument) |arg| try writer.print("argument '{s}': ", .{arg});
        if (self.message) |msg| try writer.writeAll(msg);
        if (self.value) |val| try writer.print(" (got '{s}')", .{val});
        if (self.expected) |exp| try writer.print(" (expected {s})", .{exp});
        if (self.suggestion) |sug| try writer.print("\n  Did you mean '{s}'?", .{sug});

        return aw.toOwnedSlice();
    }
};

const utils = @import("utils.zig");
const constants = @import("constants.zig");

/// Calculate Levenshtein distance between two strings for suggestions (delegates to utils).
pub const levenshteinDistance = utils.editDistance;

/// Find the closest match from a list of candidates (delegates to utils).
pub const findClosestMatch = utils.findClosest;

/// Format a parse error for display.
pub fn formatParseError(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownOption => constants.ErrorMessages.parse_unknown_option,
        error.MissingRequired => constants.ErrorMessages.parse_missing_required,
        error.MissingValue => constants.ErrorMessages.parse_missing_value,
        error.InvalidValue => constants.ErrorMessages.parse_invalid_value,
        error.TooManyValues => constants.ErrorMessages.parse_too_many_values,
        error.TooFewValues => constants.ErrorMessages.parse_too_few_values,
        error.InvalidChoice => constants.ErrorMessages.parse_invalid_choice,
        error.ConflictingArguments => constants.ErrorMessages.parse_conflicting_arguments,
        error.MissingDependency => constants.ErrorMessages.parse_missing_dependency,
        error.DuplicateArgument => constants.ErrorMessages.parse_duplicate_argument,
        error.InvalidFormat => constants.ErrorMessages.parse_invalid_format,
        error.UnexpectedPositional => constants.ErrorMessages.parse_unexpected_positional,
        error.UnknownSubcommand => constants.ErrorMessages.parse_unknown_subcommand,
        error.MissingSubcommand => constants.ErrorMessages.parse_missing_subcommand,
        error.MutuallyExclusive => constants.ErrorMessages.parse_mutually_exclusive,
        error.OutOfMemory => constants.ErrorMessages.parse_out_of_memory,
        error.Overflow => constants.ErrorMessages.parse_overflow,
        error.InvalidCharacter => constants.ErrorMessages.parse_invalid_character,
        error.RequiredIfViolation => constants.ErrorMessages.parse_required_if_violation,
        error.CircularConflict => constants.ErrorMessages.parse_circular_conflict,
        else => @errorName(err),
    };
}

/// Format a schema definition error for display.
pub fn formatSchemaError(err: SchemaError) []const u8 {
    return switch (err) {
        SchemaError.DuplicateArgument => constants.ErrorMessages.schema_duplicate_argument,
        SchemaError.InvalidShortName => constants.ErrorMessages.schema_invalid_short,
        SchemaError.InvalidLongName => constants.ErrorMessages.schema_invalid_long,
        SchemaError.MissingName => constants.ErrorMessages.schema_missing_name,
        SchemaError.EmptyName => constants.ErrorMessages.schema_empty_name,
        SchemaError.DuplicateName => constants.ErrorMessages.schema_duplicate_name,
        SchemaError.DuplicateAlias => constants.ErrorMessages.schema_duplicate_alias,
        SchemaError.InvalidConfig => constants.ErrorMessages.schema_invalid_config,
        SchemaError.PositionalAfterVariadic => constants.ErrorMessages.schema_positional_after_variadic,
        SchemaError.RequiredAfterOptional => constants.ErrorMessages.schema_required_after_optional,
        SchemaError.InvalidNargs => constants.ErrorMessages.schema_invalid_nargs,
        SchemaError.InvalidDefault => constants.ErrorMessages.schema_invalid_default,
        SchemaError.InvalidChoices => constants.ErrorMessages.schema_invalid_choices,
        SchemaError.CircularDependency => constants.ErrorMessages.schema_circular_dependency,
        SchemaError.SelfConflict => constants.ErrorMessages.schema_self_conflict,
        SchemaError.OutOfMemory => constants.ErrorMessages.schema_out_of_memory,
        SchemaError.ConflictingSelf => constants.ErrorMessages.schema_conflicting_self,
        SchemaError.InvalidRegex => constants.ErrorMessages.schema_invalid_regex,
        SchemaError.InvalidDuration => constants.ErrorMessages.schema_invalid_duration,
    };
}

/// Format a parse error with additional context into an allocated string.
/// The caller is responsible for freeing the returned slice.
pub fn formatParseErrorDetail(allocator: std.mem.Allocator, err: anyerror, ctx: ErrorContext) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(formatParseError(err));
    const detail = try ctx.format(allocator);
    defer allocator.free(detail);
    if (detail.len > 0) {
        try w.writeAll(": ");
        try w.writeAll(detail);
    }
    return aw.toOwnedSlice();
}

/// Format a validation error for display.
pub fn formatValidationError(err: ValidationError) []const u8 {
    return switch (err) {
        ValidationError.OutOfRange => constants.ErrorMessages.validation_out_of_range,
        ValidationError.TooShort => constants.ErrorMessages.validation_too_short,
        ValidationError.TooLong => constants.ErrorMessages.validation_too_long,
        ValidationError.PatternMismatch => constants.ErrorMessages.validation_pattern_mismatch,
        ValidationError.CustomValidationFailed => constants.ErrorMessages.validation_custom_failed,
        ValidationError.FileNotFound => constants.ErrorMessages.validation_file_not_found,
        ValidationError.DirectoryNotFound => constants.ErrorMessages.validation_directory_not_found,
        ValidationError.PermissionDenied => constants.ErrorMessages.validation_permission_denied,
        ValidationError.InvalidPath => constants.ErrorMessages.validation_invalid_path,
    };
}

test "levenshteinDistance" {
    try std.testing.expectEqual(@as(usize, 0), levenshteinDistance("hello", "hello"));
    try std.testing.expectEqual(@as(usize, 1), levenshteinDistance("hello", "hallo"));
    try std.testing.expectEqual(@as(usize, 3), levenshteinDistance("kitten", "sitting"));
    try std.testing.expectEqual(@as(usize, 5), levenshteinDistance("", "hello"));
}

test "findClosestMatch" {
    const candidates = [_][]const u8{ "verbose", "version", "help", "output" };
    try std.testing.expectEqualStrings("verbose", findClosestMatch("verbos", &candidates, 2).?);
    try std.testing.expectEqualStrings("version", findClosestMatch("versio", &candidates, 2).?);
    try std.testing.expectEqual(@as(?[]const u8, null), findClosestMatch("xyz", &candidates, 2));
}

test "ErrorContext.format" {
    const allocator = std.testing.allocator;

    const ctx = ErrorContext{
        .argument = "output",
        .message = "file not found",
        .value = "/invalid/path",
    };

    const formatted = try ctx.format(allocator);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "output") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "file not found") != null);
}

test "formatParseError" {
    try std.testing.expectEqualStrings("unknown option", formatParseError(ParseError.UnknownOption));
    try std.testing.expectEqualStrings("missing required argument", formatParseError(ParseError.MissingRequired));
}

test "formatSchemaError" {
    try std.testing.expectEqualStrings("duplicate argument", formatSchemaError(SchemaError.DuplicateArgument));
    try std.testing.expectEqualStrings("invalid long name", formatSchemaError(SchemaError.InvalidLongName));
}

test "formatValidationError" {
    try std.testing.expectEqualStrings("value out of range", formatValidationError(ValidationError.OutOfRange));
    try std.testing.expectEqualStrings("file not found", formatValidationError(ValidationError.FileNotFound));
}
