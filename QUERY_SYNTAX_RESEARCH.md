# Lightweight CLI-Friendly Query Syntax for Key=Value Log Filtering

This document compares various query syntax approaches for filtering structured key=value log data (like accessibility events). Each approach is evaluated for suitability in a Swift CLI tool.

---

## Executive Summary

For the kbdcmd project filtering accessibility events, the **recommended approach is a simplified logfmt-inspired syntax** combining:
- **Ease of parsing**: No external dependencies, minimal regex needed
- **Familiarity**: Similar to shell pipes users already know
- **Power**: Supports AND/OR/NOT with proper precedence
- **Extensibility**: Can add pattern matching without breaking changes

---

## 1. jq (JSON Query Language)

### Overview
jq is the de facto JSON query language, using functional programming patterns with pipes for composition.

### Syntax Examples
```bash
# Match app=Music AND NOT role=AXStaticText
.[] | select(.app == "Music" and .role != "AXStaticText")

# Combined filters with logical operators
.[] | select((.app == "Music" or .app == "Safari") and .role | startswith("AX"))

# Pipe composition for complex queries
.[] | select(.action != null) | select(.bounds | .width > 10)
```

### Operators
- **Comparison**: `==`, `!=`, `<`, `<=`, `>`, `>=`
- **Logical**: `and`, `or`, `not`
- **String**: `startswith()`, `endswith()`, `contains()`, `test(regex)`
- **Array**: `.[]`, `map()`, `select()`, `group_by()`
- **Composition**: `|` (pipe)

### Pros
- Powerful: Full functional language with many built-in functions
- Well-documented: Official manual and large community
- Familiar: De facto standard for JSON processing
- Pattern matching: Can do regex, substring, and complex comparisons

### Cons
- Heavy dependency: Requires jq binary, not suitable for bundled CLI
- Steep learning curve: Functional programming concepts
- Not optimized for key=value: Designed for JSON objects
- Verbose for simple queries: `select(.app == "Music")` vs `app=Music`
- Parsing complexity: Medium - needs expression parser

### Parsing Complexity
**Medium** - Would need a full expression evaluator similar to jq's. Not realistic for Swift without external library.

### User Familiarity
**Medium** - Users familiar with JSON workflows understand it; shell users find it unfamiliar.

### Extensibility
**Excellent** - Functional composition allows unlimited extension.

---

## 2. Logfmt Query Syntax (Heroku/Datadog Style)

### Overview
Logfmt is a simple key=value format used by Heroku and Datadog for log parsing. Query syntax is minimal but effective.

### Syntax Examples
```bash
# Datadog-style queries
@app:Music @role:!AXStaticText
@role:AXButton @action:AXPress

# With operators (Datadog Extended)
@app:"Music" AND NOT @role:"AXStaticText"
@status:[400 TO 599]  # Range queries
```

### Standard logfmt Operators
- Tag matching: `key:value`
- Negation: `key:!value` or `NOT key:value`
- String matching: `key:"value with spaces"`
- Case-insensitive: Generally case-sensitive by default
- Range queries: `key:[min TO max]`

### Pros
- Lightweight: Minimal parsing needed
- Familiar: Used by Heroku, Datadog, cloud logging services
- Readable: Very natural for shell users
- Fast to parse: Simple tokenizer sufficient
- No external deps: Easy to implement in Swift

### Cons
- Limited expressiveness: Harder to do complex boolean logic
- Inconsistent standards: Datadog, Heroku, and others differ slightly
- No wildcard matching: Some implementations lack it
- Limited operators: Fewer built-in functions than jq/SQL
- Space-separated queries: Can be ambiguous without quotes

### Parsing Complexity
**Low** - Simple tokenizer, 50-100 lines of Swift code.

### User Familiarity
**High** - Cloud engineers immediately recognize it.

### Extensibility
**Good** - Can add operators incrementally (like Datadog does).

---

## 3. SQL WHERE Clause (Simplified)

### Overview
SQL WHERE syntax is familiar to most developers but can be overly complex for CLI.

### Syntax Examples
```bash
# Simple WHERE style
app = 'Music' AND role != 'AXStaticText'
role IN ('AXButton', 'AXGroup') AND action IS NOT NULL
bounds.width > 5 AND bounds.height > 5
title LIKE '%play%'
```

### Operators
- Comparison: `=`, `!=`, `<`, `<=`, `>`, `>=`
- Logical: `AND`, `OR`, `NOT`
- String: `LIKE`, `IN`, `NOT IN`, `IS NULL`, `IS NOT NULL`
- Range: `BETWEEN x AND y`

### Pros
- Familiar: Most developers know SQL
- Clear syntax: Well-defined precedence and structure
- Expressive: Supports complex conditions
- Standard escaping: Quoted strings are standard

### Cons
- Over-engineered for CLI: Overkill for simple filtering
- Too many features: Tempting to add JOINs, aggregations
- Complex parsing: Needs full SQL parser
- Keywords are noisy: `WHERE`, `AND`, `OR` add verbosity
- Dependencies: Would need to bundle a SQL parser library
- Harder to shell-escape: Quotes and operators need escaping in shell

### Parsing Complexity
**High** - Full SQL parsing needed; complex precedence rules.

### User Familiarity
**High** - Most programmers know SQL basics.

### Extensibility
**Excellent but risky** - Easy to add features that bloat the tool.

---

## 4. grep/awk Combinations

### Overview
Traditional Unix tool composition using regular expressions and field processing.

### Syntax Examples
```bash
# Pure grep approach (limited)
walker output | grep 'app="Music"' | grep -v 'role="AXStaticText"'

# awk approach
walker output | awk -F'[ ="]+' '$2=="app" && $3=="Music" && !($5=="role" && $6=="AXStaticText")'

# Combined filters
walker output | grep 'action' | awk '$2 ~ /^AX/ { print }'
```

### Operators
- grep: Regex matching, `-v` for negation
- awk: Field splitting, pattern matching, conditional expressions
- sed: Stream editing with regex

### Pros
- Ubiquitous: Available on every Unix system
- Composable: Pipe chains are natural
- Powerful regex: Full regex engine available
- No dependencies: Built into OS
- Shell integration: Natural part of existing workflows

### Cons
- Awkward query syntax: Not designed for structured key=value
- Hard to compose complex logic: Multiple pipes become unreadable
- AND/OR logic is hacky: Need multiple `grep` or complex `awk`
- Fragile: Whitespace/quoting sensitive
- Limited to text patterns: Not aware of key=value structure
- User must learn awk/sed: High barrier to entry
- Not discoverable: No help on available fields

### Parsing Complexity
**N/A** - User writes grep/awk, not CLI tool.

### User Familiarity
**Medium** - Programmers comfortable with Unix; SREs know it well.

### Extensibility
**Low** - Not a designed-for-extension system.

---

## 5. fzf-Style Filter Syntax

### Overview
fzf's fuzzy finder uses a simple infix notation with operators for exact/regex/negation matching.

### Syntax Examples
```bash
# fzf-style queries (adapted for key=value)
app=Music  # Contains "Music"
'app="Music"  # Exact match
!AXStaticText  # Exclude containing "AXStaticText"
app=Music role=AXButton  # AND (space-separated)
app=Music | role=AXButton  # OR (pipe)
^Music  # Starts with
Music$  # Ends with
```

### Operators
- Fuzzy match: `term` (default, substring)
- Exact match: `'term`
- Negation: `!term`
- OR: `|` (single pipe)
- AND: Space (implicit)
- Anchored: `^start` or `end$`
- Regex: Optional prefix support

### Pros
- Simple and intuitive: Users learn it quickly
- Minimal syntax: Operators are memorable
- Composable: Multiple filters by space or pipe
- Fuzzy-friendly: Tolerates typos in patterns
- Low parsing complexity: Pattern-based, not expression-based
- No quotes usually needed: Unless spaces in values

### Cons
- Limited to pattern matching: No numeric comparisons
- Ambiguous in some cases: Space-based AND can conflict with values containing spaces
- Limited operators: No LIKE, BETWEEN, IN
- Less powerful: Can't do complex boolean expressions
- Fuzzy matching inappropriate for some fields: Need exact bounds matching
- Single/double quotes needed for complex cases: Similar escaping issues

### Parsing Complexity
**Very Low** - Simple pattern tokenizer, ~30 lines of Swift.

### User Familiarity
**Medium** - fzf users love it; grep users recognize patterns.

### Extensibility
**Fair** - Can add new operators but syntax gets crowded.

---

## 6. Common Expression Language (CEL)

### Overview
CEL is Google's portable expression language used in Kubernetes, Firebase, and security tools.

### Syntax Examples
```bash
# CEL-style expressions
app == 'Music' && role != 'AXStaticText'
(app == 'Music' || app == 'Safari') && action != null
title.contains('Play')
bounds.width > 5 && bounds.height > 5
role in ['AXButton', 'AXGroup']
```

### Operators
- Comparison: `==`, `!=`, `<`, `<=`, `>`, `>=`, `in`
- Logical: `&&`, `||`, `!`
- String: `.startsWith()`, `.endsWith()`, `.contains()`
- Ternary: `condition ? true_value : false_value`
- Type checking: Available

### Pros
- Standardized: Google-designed, used in production systems
- C-like syntax: Familiar to most programmers
- Safe: Designed to be safely evaluated
- Well-documented: Official spec available
- Type-aware: Can do type checking
- Mature implementations: Available in Go, Python, Java, etc.

### Cons
- Heavy dependency: Would need CEL library
- Overkill for simple CLI use: Too many features
- Complex semantics: Not designed for simple key=value
- Parsing complexity: Full expression language needed
- Swift implementation: No official Swift CEL library (would need to add)
- Learning curve: More than needed for log filtering

### Parsing Complexity
**High** - Full expression evaluator with type system.

### User Familiarity
**Low** - Not common for CLI users; primarily used in backend systems.

### Extensibility
**Excellent** - But overkill for this use case.

---

## 7. Custom Simple Query Language (Recommended)

### Overview
A minimalist query language designed specifically for key=value filtering, inspired by logfmt but optimized for CLI use.

### Syntax Examples
```bash
# Basic key=value matching
app=Music role!=AXStaticText action=AXPress

# With spaces and quotes
"app=Music Pro" role!=AXStaticText

# Logical operators
app=Music AND role!=AXStaticText AND NOT bounds=0x0
app=Music OR app=Safari
NOT role=AXStaticText

# Pattern matching (glob)
role=AX* title~Play bounds>[0,0,*,*]

# Regex support (with /)
role=/^AXButton$/i title~/play/i
```

### Proposed Specification
```
query        = filter (logical_op filter)*
logical_op   = "AND" | "OR" | (space as AND)
filter       = "NOT"? condition
condition    = key op value
key          = identifier
op           = "=" | "!=" | "~" | "!~" | ">" | "<" | ">=" | "<=" | "in" | "not-in"
value        = quoted_string | unquoted_string | regex_literal | number
quoted_string = '"' ... '"'
unquoted_string = [a-zA-Z0-9.*_-]+
regex_literal = '/' ... '/' [flags]
number        = [0-9]+
```

### Operators
- Equality: `key=value`, `key!=value`
- Pattern: `key~pattern`, `key!~pattern`
- Numeric: `key>num`, `key<num`, `key>=num`, `key<=num`
- Membership: `key in (val1,val2)`, `key not-in (val1,val2)`
- Logical: `AND`, `OR`, `NOT`
- Regex: `key~/regex/flags`

### Pros
- Minimal: Few operators, easy to learn
- Intuitive: Looks like simple command-line options
- Fast to parse: No ambiguity, 100-200 lines of Swift
- No dependencies: Pure Swift implementation
- Familiar to shell users: Resembles shell glob patterns
- Scalable parsing: Can be extended without breaking existing queries
- Good balance: Between simplicity and power
- Self-documenting: Query syntax explains itself
- Works with pipes: Easy to compose with other tools

### Cons
- New syntax: Users must learn it (but it's quick to learn)
- Limited power: Can't do things like `.width > .height`
- String-centric: Not as elegant as SQL/CEL for numeric comparisons
- Precedence rules: Need documentation for AND/OR precedence
- Case sensitivity: Default behavior needs definition

### Parsing Complexity
**Low-Medium** - Recursive descent parser, ~150 lines of well-structured Swift.

### User Familiarity
**Medium** - Looks like familiar shell/grep syntax.

### Extensibility
**Excellent** - Simple to add operators without parser rewrite.

---

## Detailed Comparison Table

| Aspect | jq | logfmt | SQL | grep/awk | fzf | CEL | Custom |
|--------|-----|--------|-----|----------|-----|-----|--------|
| **Syntax Example** | `.select(.app == "Music")` | `@app:Music` | `app = 'Music'` | `grep 'app="Music"'` | `app=Music` | `app == 'Music'` | `app=Music` |
| **AND/OR/NOT** | Yes (and/or/not) | Yes (AND/NOT) | Yes (AND/OR/NOT) | Limited | Yes (space/\|/!) | Yes (&&/\|\|/!) | Yes (AND/OR/NOT) |
| **Pattern Matching** | Yes (regex) | Limited | Yes (LIKE) | Yes (regex) | Yes (fuzzy) | Yes | Yes |
| **Numeric Comparison** | Yes | Limited | Yes | Limited | No | Yes | Yes |
| **External Dependency** | Binary | Library | Library | None | None | Library | None |
| **Parse Complexity** | High | Low | High | N/A | Very Low | High | Low-Med |
| **User Familiarity** | Med-High | High (cloud) | High | Med | Med | Low | Med |
| **Lines to Implement** | N/A | ~200 | N/A | N/A | N/A | N/A | ~150 |
| **Field Discovery** | No | Limited | No | No | No | No | **Can add** |
| **Error Messages** | Good | Limited | Good | Poor | Limited | Good | **Customizable** |
| **Performance** | Good | Excellent | Good | Good | Excellent | Good | **Excellent** |

---

## Use Case Analysis

### For kbdcmd Walker Output Filtering

Sample walker output:
```xml
<button bounds="500,400,100,50" title="Play" role="AXButton" action:AXPress />
<group bounds="300,200,200,100" title="Controls" role="AXGroup">
  <button bounds="310,210,40,40" title="Prev" role="AXButton" action:AXPress />
</group>
```

#### Filtering Requirements
1. Filter by app: `app=Music` (from walker command)
2. Filter by role: `role=AXButton`, `role!=AXStaticText`
3. Filter by action: `action=AXPress` (present/absent)
4. Filter by size: `bounds>[0,0,100,100]` (visible elements)
5. Filter by text: `title~Play` (pattern matching)
6. Compound: `app=Music AND role=AXButton AND NOT title~""` (play buttons)

#### Recommendation: Use Custom Query Language

**Why Custom?**
1. Simplicity: Implementation is straightforward
2. Perfect fit: Designed for exactly this use case
3. No bloat: Doesn't try to be a full expression language
4. Familiar: Looks like shell commands
5. Extensible: Can add operators later (like field ranges, aggregations)
6. Discoverable: Can add `--help filters` showing available fields
7. Performance: Parser is simpler, evaluator is faster

---

## Syntax Recommendations

### Recommended Syntax for kbdcmd

```bash
# Basic filtering
kbdcmd walker --app Music --filter "role=AXButton"

# Multiple conditions (AND by default)
kbdcmd walker --filter "role=AXButton app=Music"

# Explicit logical operators
kbdcmd walker --filter "app=Music AND role=AXButton"
kbdcmd walker --filter "app=Music OR app=Safari"
kbdcmd walker --filter "app=Music AND NOT role=AXStaticText"

# Pattern matching
kbdcmd walker --filter "title~play"  # Substring match
kbdcmd walker --filter "title~/^Play/i"  # Regex match

# Numeric comparisons
kbdcmd walker --filter "bounds.width>100 bounds.height>50"

# Membership
kbdcmd walker --filter "role in (AXButton,AXGroup)"
```

### Key Design Principles

1. Space = AND: Default is implicit AND when multiple filters
2. Explicit keywords for OR/NOT: Avoid ambiguity
3. Dot notation for nested fields: `bounds.width` for nested objects
4. Regex with delimiters: `/pattern/flags` for regex vs `~pattern` for substring
5. Single quotes optional: `role=AXButton` works, `role="AX Button"` for spaces
6. Field discovery: `--filter-help` shows available fields
7. Error context: Clear messages on parse errors

---

## Implementation Priority

### Phase 1: MVP (80/20 rule)
- Operators: `=`, `!=`, `~`, `!~`
- Logical: `AND`, `OR`, `NOT`
- Implicit AND for space-separated filters
- Quote handling for spaces

**Expected effort**: 100-150 lines of Swift

### Phase 2: Extended
- Numeric operators: `>`, `<`, `>=`, `<=`
- Membership: `in`, `not-in`
- Regex literals: `/pattern/flags`
- Better error messages

**Expected effort**: 50-100 lines additional

### Phase 3: Advanced (if needed)
- Field existence checks: `action?` (field exists), `!action?`
- Range matching: `bounds=[0,0,*,*]`
- Case-insensitive flags: `title~play/i`

**Expected effort**: 50+ lines

---

## Recommendations by Project Type

### For kbdcmd (Accessibility Automation)
**Recommended: Custom Query Language (Phase 1)**
- Reason: Perfect match for key=value filtering
- Users: Shell users, automation engineers
- Example: `role=AXButton title~play bounds.width>100`

### For General Log Processing Tool
**Recommended: Logfmt-inspired**
- Reason: Proven in industry, familiar to SREs
- Users: DevOps, SRE teams
- Example: `@level:error @service:api @host:prod-*`

### For JSON-centric Tool
**Recommended: jq subset or CEL**
- Reason: Match tool's primary data format
- Users: Developers, JSON experts
- Example: `.[] | select(.level == "error")`

### For Maximum Simplicity
**Recommended: grep/awk composition or fzf-style**
- Reason: No learning curve
- Users: Everyone knows grep
- Example: `walker output | grep 'role="AXButton"' | grep -v title=""` OR `role=AXButton title~`

---

## References & Further Reading

### Query Languages
- [jq Manual](https://jqlang.org/manual/)
- [Datadog Log Search Syntax](https://docs.datadoghq.com/logs/explorer/search_syntax/)
- [CEL Common Expression Language](https://cel.dev/)
- [Prometheus PromQL](https://prometheus.io/docs/prometheus/latest/querying/basics/)

### Log Processing
- [LogQL Documentation](https://grafana.com/docs/loki/latest/query/log_queries/)
- [Heroku Log Drains](https://docs.datadoghq.com/logs/guide/collect-heroku-logs/)

### CLI Design
- [fzf GitHub](https://github.com/junegunn/fzf)
- [ripgrep Guide](https://github.com/BurntSushi/ripgrep/blob/master/GUIDE.md)

---

## Conclusion

For **kbdcmd's accessibility event filtering**, a **custom, minimal query language** is the best choice:

1. Simple to implement: 150-200 lines of Swift for MVP
2. No dependencies: Pure Swift, ships with binary
3. Intuitive syntax: `role=AXButton app=Music` feels natural
4. Extensible: Can add operators without parser rewrite
5. Right complexity: Not overpowered like SQL/CEL, not underpowered like grep
6. Perfect fit: Designed exactly for this use case

The recommended syntax balances power and simplicity:
```bash
# MVP Phase 1
kbdcmd walker --filter "app=Music role=AXButton"
kbdcmd walker --filter "app=Music AND NOT role=AXStaticText"
kbdcmd walker --filter "title~play role=/^AX.*/"

# Phase 2 additions
kbdcmd walker --filter "bounds.width>100"
kbdcmd walker --filter "role in (AXButton,AXGroup)"
```
