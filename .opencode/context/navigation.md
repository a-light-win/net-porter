# Context Navigation

This directory contains organized knowledge for the net-porter project.
Agents should consult relevant files before making code changes.

## Structure

```
context/
├── navigation.md              # This file - context index
└── standards/                 # Coding rules and conventions
    └── zig-coding-standards.md  # Zig coding standards (MUST READ)
```

## Priority Order

1. **`standards/zig-coding-standards.md`** - Mandatory rules for all Zig code
   - Read this BEFORE writing or modifying any Zig code
   - Contains critical rules like POSIX API selection policy

## Usage

- **Before coding**: Check standards/ for applicable rules
- **Before review**: Verify changes comply with standards
- **When in doubt**: Refer to standards as the source of truth
