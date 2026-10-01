/// The JSON Schema of the sprite spec, version 1 (`menusprite schema`), for editors and agents that check a
/// spec before sending it. The compiler is the authority: it also checks what a schema cannot (value ids that
/// exist, rule targets, reading ids on this Mac, the `when` grammar). Spec: `docs/agent-authoring.md`.
public enum SpecSchema {
    public static let json = ##"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://menusprite.prerakgada.in/schema/sprite-spec-1.json",
      "title": "MenuSprite sprite spec, version 1",
      "description": "One sprite: its values (readings, commands, fixed text), its menu-bar face, rules that restyle it, the board a click opens, and files for its scripts. Everything except menusprite and name is optional.",
      "type": "object",
      "required": ["menusprite", "name"],
      "properties": {
        "menusprite": {"const": 1, "description": "The format version."},
        "id": {"type": "string", "format": "uuid", "description": "Present on sprites read back; apply matches by it, else by name."},
        "name": {"type": "string", "minLength": 1, "description": "Saved cut to 40 characters; apply matches an existing sprite by that name, case-insensitively."},
        "icon": {"$ref": "#/$defs/symbol", "description": "The sprite's identity in lists and the board header; also the face when face is omitted."},
        "enabled": {"type": "boolean", "default": true, "description": "Values run and the item can show."},
        "menuBar": {"type": "boolean", "default": true, "description": "Shown in the menu bar."},
        "side": {"enum": ["left", "right"], "default": "right", "description": "left puts the sprite on the left strip."},
        "every": {
          "description": "Seconds between reading samples. Other values are snapped to the nearest of these.",
          "anyOf": [{"enum": [1, 2, 5, 10, 30, 60]}, {"$ref": "#/$defs/durationText"}],
          "default": 2
        },
        "values": {"type": "array", "items": {"$ref": "#/$defs/value"}},
        "face": {"$ref": "#/$defs/node", "description": "What the menu bar draws. Omitted: the icon alone."},
        "rules": {"type": "array", "items": {"$ref": "#/$defs/rule"}},
        "board": {
          "description": "What a click opens. Omitted or null: the classic panel.",
          "oneOf": [{"type": "null"}, {"$ref": "#/$defs/board"}]
        },
        "files": {
          "description": "Scripts and data written to the sprite's own folder, where its commands run with SPRITE_DIR set. Omitted keeps the files there; {} removes them. Content starting with #! is made executable.",
          "type": ["object", "null"],
          "maxProperties": 20,
          "propertyNames": {"pattern": "^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$"},
          "additionalProperties": {"type": "string", "maxLength": 262144}
        }
      },
      "additionalProperties": false,

      "$defs": {
        "symbol": {"type": "string", "minLength": 1, "description": "An SF Symbol name, such as cpu, bolt.fill or arrow.triangle.pull."},
        "colorName": {"enum": ["red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink", "brown", "gray", "white", "black"], "description": "Apple's system colours, kept as names: each is drawn in its light or dark shade to suit the bar and board."},
        "hex": {"type": "string", "pattern": "^#?[0-9A-Fa-f]{6}$"},
        "color": {
          "description": "inherit (the parent's; the default), auto (follows the menu bar), #RRGGBB (fixed), or one of Apple's system colours by name (adapts to light and dark).",
          "anyOf": [{"enum": ["inherit", "auto"]}, {"$ref": "#/$defs/colorName"}, {"$ref": "#/$defs/hex"}]
        },
        "background": {
          "description": "A rounded fill behind the block: none (the default), #RRGGBB or a colour name.",
          "anyOf": [{"const": "none"}, {"$ref": "#/$defs/colorName"}, {"$ref": "#/$defs/hex"}]
        },
        "durationText": {"type": "string", "pattern": "^\\s*[0-9]+(\\.[0-9]+)?\\s*(s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days)?\\s*$"},
        "duration": {
          "description": "Seconds as a number, or \"30s\", \"5m\", \"1h\", \"1d\". Clamped to 2 s – 1 day.",
          "anyOf": [{"type": "number", "minimum": 2, "maximum": 86400}, {"$ref": "#/$defs/durationText"}]
        },
        "timeout": {"type": "number", "minimum": 1, "maximum": 60, "default": 10, "description": "Seconds before the command is killed."},
        "actionTimeout": {"type": "number", "minimum": 1, "maximum": 600, "default": 30, "description": "Seconds a command run by a click may take before it is stopped."},
        "valueID": {"type": "string", "minLength": 1, "pattern": "^(?:[A-Za-z0-9_]|[^\\x00-\\x7F])+$", "description": "A value's id: letters (any script), digits and _, at most 32 characters. Texts use it as {id}."},
        "valueRef": {"oneOf": [{"$ref": "#/$defs/valueID"}, {"type": "null"}]},
        "id": {"type": "string", "pattern": "^[A-Za-z0-9_-]{1,64}$", "description": "Unique across the face and the board; rules name their targets by it."},
        "template": {
          "description": "Text mixed with {value} references, e.g. \"CPU {cpu}%\". The list form is exact: strings are literal and {\"value\": id} objects are references.",
          "anyOf": [
            {"type": "string"},
            {"type": "number"},
            {"type": "array", "items": {"anyOf": [
              {"type": "string"},
              {"type": "object", "required": ["value"], "properties": {"value": {"$ref": "#/$defs/valueID"}}, "additionalProperties": false}
            ]}}
          ]
        },

        "value": {
          "type": "object",
          "required": ["id"],
          "properties": {
            "id": {"$ref": "#/$defs/valueID"},
            "name": {"type": "string", "description": "Defaults to the reading's name, else the id."},
            "reading": {"type": "string", "description": "A reading id from `menusprite readings`, such as cpu.usage."},
            "command": {"type": "string", "minLength": 1, "description": "Runs in /bin/zsh -f -c, in the sprite's folder when it has files."},
            "text": {"type": ["string", "number"], "description": "Fixed text."},
            "decimals": {"type": "integer", "minimum": 0, "maximum": 2, "default": 0},
            "unit": {"type": "boolean", "default": true, "description": "Readings: show the unit."},
            "fahrenheit": {"type": "boolean", "default": false},
            "bits": {"type": "boolean", "default": false},
            "clock": {"type": "boolean", "default": false, "description": "Readings in seconds (a limit's reset): write the time it ends, \"Thu 16:30\", instead of \"2h 14m\"."},
            "every": {"$ref": "#/$defs/duration", "default": 60},
            "timeout": {"$ref": "#/$defs/timeout"},
            "parse": {"enum": ["text", "number", "json"], "default": "text", "description": "text = first line, number = first number, json + path = a dotted path."},
            "path": {"type": "string", "description": "With parse json: a dotted path such as data.items.0.name."},
            "suffix": {"type": "string", "description": "Appended to a command's value."},
            "background": {"type": "boolean", "default": false, "description": "Keep a board-only command running while the board is closed (a chart needs its history)."}
          },
          "oneOf": [{"required": ["reading"]}, {"required": ["command"]}, {"required": ["text"]}],
          "additionalProperties": false
        },

        "nodeProps": {
          "type": "object",
          "properties": {
            "id": {"$ref": "#/$defs/id"},
            "name": {"type": "string"},
            "color": {"$ref": "#/$defs/color"},
            "size": {"type": "number", "minimum": 4, "maximum": 40, "description": "Points: text size, an icon's height, a level bar's width."},
            "weight": {"enum": ["regular", "medium", "semibold", "bold", "heavy"], "default": "regular"},
            "tabular": {"type": "boolean", "default": true, "description": "Fixed-width digits."},
            "opacity": {"type": "number", "minimum": 0, "maximum": 1, "default": 1},
            "align": {"enum": ["leading", "center", "trailing"], "default": "center"},
            "gap": {"type": "number", "minimum": 0, "description": "Between a container's children: 4 in a row, 1.5 in a column."},
            "justify": {"enum": ["start", "center", "end", "spaceBetween", "even"], "default": "center"},
            "padding": {"type": "number", "minimum": 0, "description": "A container's side padding: 3 on the root, else 0."},
            "hidden": {"type": "boolean", "default": false},
            "shrink": {"type": "boolean", "default": false, "description": "Text gives up size before it widens."},
            "chargeInside": {"type": "boolean", "default": true, "description": "Battery: draw the charge inside the glyph."},
            "max": {"type": "number", "exclusiveMinimum": 0, "default": 100, "description": "Level bar: the value that fills it."}
          }
        },
        "node": {
          "description": "A face node: an object with exactly one kind key, a bare string (a text node) or a list (a row).",
          "oneOf": [
            {"type": "string"},
            {"type": "number"},
            {"type": "array", "items": {"$ref": "#/$defs/node"}},
            {"type": "object", "required": ["row"], "properties": {"row": {"type": "array", "items": {"$ref": "#/$defs/node"}}}, "allOf": [{"$ref": "#/$defs/nodeProps"}], "unevaluatedProperties": false},
            {"type": "object", "required": ["column"], "properties": {"column": {"type": "array", "items": {"$ref": "#/$defs/node"}}}, "allOf": [{"$ref": "#/$defs/nodeProps"}], "unevaluatedProperties": false},
            {"type": "object", "required": ["text"], "properties": {"text": {"$ref": "#/$defs/template"}}, "allOf": [{"$ref": "#/$defs/nodeProps"}], "unevaluatedProperties": false},
            {"type": "object", "required": ["icon"], "properties": {"icon": {"$ref": "#/$defs/symbol"}}, "allOf": [{"$ref": "#/$defs/nodeProps"}], "unevaluatedProperties": false},
            {"type": "object", "required": ["bar"], "properties": {"bar": {"$ref": "#/$defs/valueRef"}}, "allOf": [{"$ref": "#/$defs/nodeProps"}], "unevaluatedProperties": false},
            {"type": "object", "required": ["battery"], "properties": {"battery": {"$ref": "#/$defs/valueRef"}}, "allOf": [{"$ref": "#/$defs/nodeProps"}], "unevaluatedProperties": false}
          ]
        },

        "rule": {
          "type": "object",
          "description": "Rules run top to bottom and a later rule wins. when: value[.pace] op operand, joined by ' and ' or by ' or ' (not both); ops > >= < <= == != contains, 'is missing', 'is present'; operands are numbers, 'quoted' or \"quoted\" text, or bare words.",
          "properties": {
            "id": {"$ref": "#/$defs/id"},
            "name": {"type": "string"},
            "enabled": {"type": "boolean", "default": true},
            "when": {"type": "string"},
            "match": {"enum": ["all", "any"], "description": "Only needed for one condition; and/or in when decide it otherwise."},
            "then": {"$ref": "#/$defs/actions"},
            "cases": {"type": "array", "items": {"$ref": "#/$defs/case"}},
            "else": {"$ref": "#/$defs/actions"}
          },
          "anyOf": [{"required": ["when"]}, {"required": ["cases"]}, {"required": ["else"]}],
          "not": {"required": ["when", "cases"]},
          "additionalProperties": false
        },
        "case": {
          "type": "object",
          "required": ["when"],
          "properties": {
            "when": {"type": "string"},
            "match": {"enum": ["all", "any"]},
            "then": {"$ref": "#/$defs/actions"}
          },
          "additionalProperties": false
        },
        "actions": {"oneOf": [{"type": "array", "items": {"$ref": "#/$defs/action"}}, {"$ref": "#/$defs/action"}]},
        "action": {
          "type": "object",
          "description": "A target (a face node's or board block's id) and one or more effects.",
          "required": ["target"],
          "minProperties": 2,
          "properties": {
            "target": {"$ref": "#/$defs/id"},
            "color": {"$ref": "#/$defs/color"},
            "hide": {"const": true},
            "show": {"const": true},
            "icon": {"$ref": "#/$defs/symbol"},
            "text": {"$ref": "#/$defs/template"},
            "opacity": {"type": "number", "minimum": 0, "maximum": 1}
          },
          "additionalProperties": false
        },

        "board": {
          "type": "object",
          "description": "The board, and the properties of its own top stack (spacing defaults to 10).",
          "properties": {
            "width": {"type": "number", "minimum": 260, "maximum": 560, "default": 360},
            "header": {"type": "boolean", "default": true, "description": "The icon, name and Configure… across the top."},
            "blocks": {"type": "array", "items": {"$ref": "#/$defs/block"}}
          },
          "allOf": [{"$ref": "#/$defs/blockProps"}],
          "unevaluatedProperties": false
        },
        "blockProps": {
          "type": "object",
          "properties": {
            "id": {"$ref": "#/$defs/id"},
            "name": {"type": "string"},
            "color": {"$ref": "#/$defs/color"},
            "background": {"$ref": "#/$defs/background"},
            "align": {"enum": ["leading", "center", "trailing"], "default": "leading"},
            "spacing": {"type": "number", "minimum": 0, "description": "Between a stack's, row's or card's blocks (8)."},
            "padding": {"type": "number", "minimum": 0, "default": 0},
            "hidden": {"type": "boolean", "default": false},
            "opacity": {"type": "number", "minimum": 0, "maximum": 1, "default": 1},
            "height": {"type": "number", "minimum": 4, "description": "Chart 44, output 90, image 120, energy 640, accounts 520."},
            "max": {"type": "number", "exclusiveMinimum": 0, "default": 100, "description": "Gauge: the value that fills it."},
            "limit": {"type": "integer", "minimum": 1, "maximum": 100, "description": "Process list rows (8)."},
            "font": {"enum": ["huge", "title", "headline", "body", "caption", "mono"], "default": "body"},
            "fit": {"type": "boolean", "default": false, "description": "Inside a row: the block's natural width instead of an equal share."}
          }
        },
        "clickable": {
          "description": "What a click on the block does: at most one of run (a command), open (a link), app (name, bundle id or path), copy (a text template) or refresh. timeout is how long a run may take.",
          "properties": {
            "run": {"type": "string"}, "open": {"type": "string"}, "app": {"type": "string"}, "copy": {"type": "string"},
            "refresh": {"const": true}, "timeout": {"$ref": "#/$defs/actionTimeout"}
          },
          "oneOf": [
            {"required": ["run"]}, {"required": ["open"]}, {"required": ["app"]}, {"required": ["copy"]}, {"required": ["refresh"]},
            {"not": {"anyOf": [{"required": ["run"]}, {"required": ["open"]}, {"required": ["app"]}, {"required": ["copy"]}, {"required": ["refresh"]}]}}
          ]
        },
        "textLines": {
          "properties": {
            "lines": {"type": "integer", "minimum": 0, "default": 0, "description": "At most this many lines; 0 = as many as the text needs."},
            "truncate": {"enum": ["tail", "middle", "head"], "default": "tail", "description": "Where text held to its lines is cut."}
          }
        },
        "blocks": {"type": "array", "items": {"$ref": "#/$defs/block"}},
        "block": {
          "description": "A board block: an object with exactly one kind key (a bare string is a text block).",
          "oneOf": [
            {"type": "string"},
            {"type": "object", "required": ["stack"], "properties": {"stack": {"$ref": "#/$defs/blocks"}}, "allOf": [{"$ref": "#/$defs/blockProps"}, {"$ref": "#/$defs/clickable"}], "unevaluatedProperties": false},
            {"type": "object", "required": ["row"], "properties": {"row": {"$ref": "#/$defs/blocks"}}, "allOf": [{"$ref": "#/$defs/blockProps"}, {"$ref": "#/$defs/clickable"}], "unevaluatedProperties": false},
            {"type": "object", "required": ["card"], "properties": {"card": {"$ref": "#/$defs/blocks"}, "title": {"$ref": "#/$defs/template"}}, "allOf": [{"$ref": "#/$defs/blockProps"}, {"$ref": "#/$defs/clickable"}], "unevaluatedProperties": false},
            {"type": "object", "required": ["divider"], "properties": {"divider": {"const": true}}, "allOf": [{"$ref": "#/$defs/blockProps"}], "unevaluatedProperties": false},
            {"type": "object", "required": ["space"], "properties": {"space": {"anyOf": [{"type": "number"}, {"const": true}], "description": "Empty height in points (true: 12)."}}, "allOf": [{"$ref": "#/$defs/blockProps"}], "unevaluatedProperties": false},
            {"type": "object", "required": ["text"], "properties": {"text": {"$ref": "#/$defs/template"}, "icon": {"$ref": "#/$defs/symbol"}}, "allOf": [{"$ref": "#/$defs/blockProps"}, {"$ref": "#/$defs/clickable"}, {"$ref": "#/$defs/textLines"}], "unevaluatedProperties": false},
            {"type": "object", "required": ["value"], "properties": {"value": {"$ref": "#/$defs/valueRef"}, "caption": {"$ref": "#/$defs/template"}, "detail": {"$ref": "#/$defs/template"}}, "allOf": [{"$ref": "#/$defs/blockProps"}, {"$ref": "#/$defs/clickable"}, {"$ref": "#/$defs/textLines"}], "unevaluatedProperties": false},
            {"type": "object", "required": ["chart"], "properties": {"chart": {"$ref": "#/$defs/valueRef"}, "caption": {"$ref": "#/$defs/template"}}, "allOf": [{"$ref": "#/$defs/blockProps"}], "unevaluatedProperties": false},
            {"type": "object", "required": ["gauge"], "properties": {"gauge": {"$ref": "#/$defs/valueRef"}, "caption": {"$ref": "#/$defs/template"}, "detail": {"$ref": "#/$defs/template"}}, "allOf": [{"$ref": "#/$defs/blockProps"}], "unevaluatedProperties": false},
            {"type": "object", "required": ["stats"], "properties": {"stats": {"type": "array", "items": {"$ref": "#/$defs/valueID"}}}, "allOf": [{"$ref": "#/$defs/blockProps"}, {"$ref": "#/$defs/clickable"}], "unevaluatedProperties": false},
            {
              "type": "object", "required": ["button"],
              "description": "One action: run (a command), open (a link), app (name, bundle id or path), copy (a text template) or refresh.",
              "properties": {"button": {"$ref": "#/$defs/template"}, "icon": {"$ref": "#/$defs/symbol"}},
              "allOf": [{"$ref": "#/$defs/blockProps"}, {"$ref": "#/$defs/clickable"}, {"$ref": "#/$defs/textLines"}], "unevaluatedProperties": false
            },
            {
              "type": "object", "required": ["toggle"],
              "description": "A switch showing a value (on when it is a non-zero number or one of true on yes enabled active up connected running), running on/off.",
              "properties": {
                "toggle": {"$ref": "#/$defs/template"}, "icon": {"$ref": "#/$defs/symbol"}, "value": {"$ref": "#/$defs/valueRef"},
                "on": {"type": "string"}, "off": {"type": "string"}, "timeout": {"$ref": "#/$defs/actionTimeout"}
              },
              "allOf": [{"$ref": "#/$defs/blockProps"}], "unevaluatedProperties": false
            },
            {"type": "object", "required": ["output"], "properties": {"output": {"$ref": "#/$defs/valueRef"}}, "allOf": [{"$ref": "#/$defs/blockProps"}], "unevaluatedProperties": false},
            {
              "type": "object", "required": ["script"],
              "description": "SwiftBar rows: each output line is a row, 'Text | color=red sfimage=bolt href=… bash=\"…\" size=13 font=Menlo'; --- divides; leading -- indents.",
              "properties": {"script": {"type": "string"}, "every": {"$ref": "#/$defs/duration"}, "timeout": {"$ref": "#/$defs/timeout"}},
              "allOf": [{"$ref": "#/$defs/blockProps"}], "unevaluatedProperties": false
            },
            {
              "type": "object", "required": ["blocks"],
              "description": "The command prints blocks of this vocabulary as JSON (a list, or {\"blocks\": [...]}), drawn in place. It may not print blocks, script or the premade panels.",
              "properties": {"blocks": {"type": "string"}, "every": {"$ref": "#/$defs/duration"}, "timeout": {"$ref": "#/$defs/timeout"}},
              "allOf": [{"$ref": "#/$defs/blockProps"}], "unevaluatedProperties": false
            },
            {"type": "object", "required": ["image"], "properties": {"image": {"type": "string", "description": "A file (absolute, ~/…, or in the sprite's folder) or an https:// image."}}, "allOf": [{"$ref": "#/$defs/blockProps"}, {"$ref": "#/$defs/clickable"}], "unevaluatedProperties": false},
            {"type": "object", "required": ["processes"], "properties": {"processes": {"enum": ["cpu", "memory", "power"]}}, "allOf": [{"$ref": "#/$defs/blockProps"}], "unevaluatedProperties": false},
            {"type": "object", "required": ["energy"], "properties": {"energy": {"const": true}}, "allOf": [{"$ref": "#/$defs/blockProps"}], "unevaluatedProperties": false},
            {"type": "object", "required": ["accounts"], "properties": {"accounts": {"const": true}}, "allOf": [{"$ref": "#/$defs/blockProps"}], "unevaluatedProperties": false},
            {"type": "object", "required": ["readings"], "properties": {"readings": {"const": true}}, "allOf": [{"$ref": "#/$defs/blockProps"}], "unevaluatedProperties": false}
          ]
        }
      }
    }
    """##
}
