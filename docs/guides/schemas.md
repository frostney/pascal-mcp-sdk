# Schemas

## Executive Summary

Tool schemas are written in Pascal, not JSON. The fluent builder
(`ObjectSchema.AddString(...)`) covers the flat object schemas most
tools need; **argument classes** (`TMCPArgs` descendants) go further —
the class *is* the schema, expanded via RTTI, and your handler
receives a populated, validated instance. Richer schemas use the raw
JSON-string or definition-object overloads, validated at registration
against the subset the server can enforce.

## The fluent builder

`ObjectSchema` starts an object schema; each `Add*` call declares a
property and returns the builder for chaining:

```pascal
Server.RegisterTool('search', 'Search the product catalog',
  ObjectSchema
    .AddString('query', 'Search terms')
    .AddInteger('limit', 'Maximum results', False),
  SearchHandler);
```

- `AddString`, `AddNumber`, `AddInteger`, `AddBoolean` — one call per
  property, each with an optional description.
- Properties are **required by default**; pass `False` as the third
  argument to make one optional.
- The builder emits the JSON Schema 2020-12 subset the server
  enforces, so calls are validated against exactly what you declared.

An output schema can be passed alongside the input schema — the
two-schema `RegisterTool` overloads — declaring the shape of your
tool's `structuredContent`:

```pascal
Server.RegisterTool('add', 'Add two numbers',
  ObjectSchema.AddNumber('a').AddNumber('b'),      // input
  ObjectSchema.AddNumber('sum', 'The result'),     // output
  AddHandler);
```

## Typed argument classes

Skip the schema entirely and let a class expand into it. A `TMCPArgs`
descendant's **published properties are the schema**; the server
validates the arguments against it and hands your handler a populated
instance:

```pascal
type
  TAddArgs = class(TMCPArgs)
  private
    FA, FB: Double;
  published
    property a: Double read FA write FA;
    property b: Double read FB write FB;
  end;

function Add(AArgs: TMCPArgs;
  const ACtx: TMCPRequestContext): TMCPToolResult;
begin
  with AArgs as TAddArgs do
    Result := MCPTextResult(FloatToStr(a + b));
end;

// the class IS the schema: {a: number, b: number}, both required
Server.RegisterTool('add', 'Add two numbers', TAddArgs, Add);
```

Missing or mistyped arguments are rejected as in-band `isError`
results before the handler runs; unknown keys are ignored.

**Type mapping.** Published properties map to JSON Schema types:
string kinds → `string`, floats → `number`, integer kinds →
`integer`, `Boolean` → `boolean`, and enums → `string` with the enum
names as allowed values.

**Optionality** uses the standard property directives:

- `default 3` makes an ordinal property optional with that schema
  default — seeded into the instance when the argument is omitted.
- `stored False` makes any property optional without a default.

Everything else is required, matching the fluent builder's stance.

**Why classes, not records?** FPC 3.2.2 RTTI only exposes field names
for published class properties — records have no queryable field
names, so the expansion would be impossible.

**Typed output too.** The two-class overload takes an output class as
well; the handler builds an instance and `MCPStructuredResult`
serializes it:

```pascal
type
  TSumResult = class(TMCPArgs)
  private
    FSum: Double;
  published
    property sum: Double read FSum write FSum;
  end;

function AddHandler(AArgs: TMCPArgs;
  const ACtx: TMCPRequestContext): TMCPToolResult;
var
  Res: TSumResult;
begin
  Res := TSumResult.Create;
  Res.sum := (AArgs as TAddArgs).a + (AArgs as TAddArgs).b;
  Result := MCPStructuredResult('The sum is ' + FloatToStr(Res.sum), Res);
end;

Server.RegisterTool('add', 'Add two numbers', TAddArgs, TSumResult,
  AddHandler);
```

## Raw schemas

For schemas beyond what the builder or RTTI can express — `$ref`,
nested objects, titles and annotations, per-property descriptions —
register the JSON directly, as a string or a `TJSONObject`
definition:

```pascal
Server.RegisterTool('greet_user',
  'Greet a person; asks who to greet via elicitation (MRTR)',
  '{"type":"object"}', GreetUserHandler);
```

Raw schemas are parsed for well-formedness at registration
(`EMCPServer` on error) — a malformed schema fails at startup, not at
call time.

## The enforced subset

The server enforces a deliberate subset of JSON Schema 2020-12 —
`type`, `description`, `title`, `properties`, `required`, `enum`,
`default` — exactly the dialect the builders emit. Every raw-schema
registration is checked against that subset at startup: a schema using
a keyword outside it **fails at registration, naming the keyword**,
instead of being silently under-validated at call time.

The escape hatch is `.ApplicationValidated`:

```pascal
Server.RegisterTool('complex', 'Tool with a rich schema',
  RichSchemaJson, ComplexHandler).ApplicationValidated;
```

That publishes the full schema to clients unchanged, skips server-side
argument validation, and hands the job to your handler — report
violations as in-band `MCPErrorResult`s so the model can correct
itself.
